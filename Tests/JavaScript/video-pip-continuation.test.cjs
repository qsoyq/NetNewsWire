const assert = require('node:assert/strict');
const { readFileSync, mkdtempSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { execFileSync } = require('node:child_process');
const { test } = require('node:test');

const source = readFileSync(resolve(__dirname, '../../iOS/Article/VideoPlayerManager.swift'), 'utf8');
const policy = source.slice(source.indexOf('nonisolated struct VideoPlaybackRecovery'), source.indexOf('// MARK: - AVPlayerViewControllerDelegate'));
const videoPath = resolve(__dirname, '../NetNewsWire-iOSTests/Resources/video-preview.mp4');

function method(signature) {
    const start = source.indexOf(signature);
    assert.notEqual(start, -1, signature);
    let depth = 0;
    for (let i = source.indexOf('{', start); i < source.length; i++) {
        if (source[i] === '{') depth++;
        if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1).replace(/^private /, '');
    }
    throw new Error(`Unterminated method: ${signature}`);
}

// Keep the real item installation, observers, sampling, and end transitions together.
const methods = [
    'private var canContinuePlayback:', 'private var canRecoverPlayback:',
    'private func handleAudioInterruption(', 'private func resumePendingVideoEnd(',
    'private func handleExplicitPlaybackResume(',
    'private func cancelRecovery(', 'private func installPlaybackItem(',
    'private func requestPlayback(', 'private func restorePlaybackPosition(',
    'private func samplePlayback(', 'private func commitPlaybackProgress(',
    'private func suspendRecovery(', 'private func handlePlaybackFailure(',
    'private func startNextVideo(', 'private func observePlayerItemEnd(',
    'private func removeEndObserver(', 'private func observePlaybackDiagnostics(',
    'private func handleVideoEnded(', 'enum PlaybackEndAction:',
    'static func playbackEndAction(', 'static func isCurrentPlaybackItem(',
    'private func nextArticleForPlayback('
].map(method).join('\n');

function harness(scenario) {
    return `
import Foundation
import AVFoundation
import Darwin
${policy}
final class Article: Hashable {
    let articleID: String
    let accountID = "account"
    let body: String? = "video"
    var read = false
    init(_ id: String) { articleID = id }
    static func == (lhs: Article, rhs: Article) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(articleID) }
}
@MainActor final class NetworkMonitor {
    static let shared = NetworkMonitor()
    var isConnected = true
}
@MainActor final class SceneCoordinator {
    var currentArticle: Article?
    var isArticleQuickSettingsPresented = false
    var nextArticle: Article? { nil }
    func articleFor(_ id: String) -> Article? { nil }
    func findNextArticle(_ article: Article) -> Article? { nil }
    func retainArticleForVideoPlayback(_ article: Article) {}
    func selectNextArticleAfterVideo() { preconditionFailure("Background playback must not navigate") }
    enum Animation { case navigation, scroll }
    func selectArticle(_ article: Article, animations: [Animation]) { currentArticle = article; article.read = true }
}
@MainActor final class UIApplication {
    enum State: Int { case active, background }
    static let shared = UIApplication()
    var applicationState = State.background
}
@MainActor final class AppDefaults {
    static let shared = AppDefaults()
    var pipAutoPlayNextVideo = true
    var autoGotoNextAfterVideo = true
}
@MainActor struct AccountManager {
    static let shared = AccountManager()
    let isSuspended = false
}
struct AppDelegate { func resumeDatabaseProcessingIfNecessary() {} }
let appDelegate = AppDelegate()
enum StatusKey { case read }
func markArticles(_ articles: Set<Article>, statusKey: StatusKey, flag: Bool) { articles.forEach { $0.read = flag } }
enum ArticleMediaLog {
    enum Level { case warning, info }
    static func log(_ level: Level, operation: String, message: String) { print("LOG \\(operation) \\(message)") }
}
typealias NotificationActionLog = ArticleMediaLog
struct DiagnosticLogger { func info(_ message: String) {} }
@MainActor final class Harness {
    static let logger = DiagnosticLogger()
    var player: AVPlayer? = AVPlayer()
    var coordinator: SceneCoordinator? = SceneCoordinator()
    var playbackArticles = [Article("A"), Article("B"), Article("C")]
    var playbackIndex: Int?
    var currentArticleID: String?
    var pendingPlaybackArticle: Article?
    var playbackURL: URL?
    var playbackSessionID = UUID()
    var playbackRequestID = 0
    var playbackRequestStartUptime: TimeInterval = 0
    var recovery = VideoPlaybackRecovery()
    var consecutiveFailures = 0
    var attemptResolved = false
    var playbackRequested = false
    var ignoredPauseRequestID: Int?
    var resumePosition: Double = 0
    var pendingSeekPosition: Double?
    var seekingForRecovery = false
    var audioInterrupted = false
    var pendingVideoEnd = false
    var recoveryTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
    var isPiPActive = true
    var endObserver: NSObjectProtocol?
    var playerItemStatusObservation: NSKeyValueObservation?
    var playerTimeControlObservation: NSKeyValueObservation?
    var playbackDiagnosticObservers = [NSObjectProtocol]()
    var finished = false
    static func extractFirstVideoURL(from html: String?) -> URL? { URL(fileURLWithPath: "${videoPath}") }
    func logPlaybackDiagnostics(for item: AVPlayerItem, event: String, error: Error? = nil) {}
    func finishPlaybackSession(animated: Bool = true, completion: (() -> Void)? = nil) {
        finished = true
        cancelRecovery()
        removeEndObserver()
        completion?()
    }
    ${methods}
}
Task { try? await Task.sleep(for: .seconds(12)); print("TIMEOUT"); exit(2) }
Task { @MainActor in
    let manager = Harness()
    manager.player?.isMuted = true
    manager.startNextVideo(manager.playbackArticles[0], url: URL(fileURLWithPath: "${videoPath}"))
    ${scenario}
    for _ in 0..<100 {
        if manager.finished { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    guard manager.finished, manager.currentArticleID == "C", manager.playbackRequestID == 3,
        manager.playbackArticles.allSatisfy({ $0.read }), manager.coordinator?.currentArticle == nil else {
        print("FAILED article=\\(manager.currentArticleID ?? "nil") request=\\(manager.playbackRequestID) interrupted=\\(manager.audioInterrupted) resolved=\\(manager.attemptResolved)")
        exit(1)
    }
    print("three background videos finished exactly once")
    exit(0)
}
// Unlike dispatchMain(), this keeps Foundation's main OperationQueue on the main thread.
RunLoop.main.run()
`;
}

const deferredEnd = `
    for _ in 0..<100 {
        if (manager.player?.currentTime().seconds ?? 0) > 0.05 { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    manager.player?.pause()
    try? await Task.sleep(for: .milliseconds(20))
    manager.handleAudioInterruption(began: true, shouldResume: false)
    manager.playbackRequested = true
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: manager.player?.currentItem)
    try? await Task.sleep(for: .milliseconds(20))
    precondition(manager.pendingVideoEnd && manager.attemptResolved && manager.playbackRequestID == 1)
`;

function run(scenario) {
    const directory = mkdtempSync(join(tmpdir(), 'nnw-pip-continuation-'));
    try {
        const file = join(directory, 'main.swift');
        writeFileSync(file, harness(scenario));
        return execFileSync('swift', ['-suppress-warnings', file], { encoding: 'utf8', timeout: 30000 });
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
}

test('production AVPlayer observers continue three background videos without article navigation', () => {
    assert.match(run(''), /three background videos finished exactly once/);
});

test('explicit playback after an interruption clears stale state and preserves background continuation', () => {
    assert.match(run(`
    try? await Task.sleep(for: .milliseconds(200))
    manager.handleAudioInterruption(began: true, shouldResume: false)
    manager.player?.pause()
    try? await Task.sleep(for: .milliseconds(100))
    if let item = manager.player?.currentItem { manager.requestPlayback(for: item) }
    `), /three background videos finished exactly once/);
});

test('actual playback progress clears an unpaired interruption without an explicit rate change', () => {
    assert.match(run(`
    try? await Task.sleep(for: .milliseconds(200))
    manager.handleAudioInterruption(began: true, shouldResume: false)
    `), /three background videos finished exactly once/);
});

test('a consumed end notification resumes exactly once when the interruption ends', () => {
    assert.match(run(`${deferredEnd}
    manager.handleAudioInterruption(began: false, shouldResume: true)
    precondition(!manager.pendingVideoEnd && manager.currentArticleID == "B" && manager.playbackRequestID == 2)
    manager.handleAudioInterruption(began: false, shouldResume: true)
    precondition(manager.playbackRequestID == 2)
    `), /three background videos finished exactly once/);
});

test('interruption end without shouldResume waits for explicit Play before advancing', () => {
    assert.match(run(`${deferredEnd}
    manager.handleAudioInterruption(began: false, shouldResume: false)
    try? await Task.sleep(for: .milliseconds(100))
    precondition(manager.pendingVideoEnd && manager.playbackRequestID == 1)
    manager.player?.play()
    `), /three background videos finished exactly once/);
});

test('a user pause while continuation is deferred prevents automatic resumption', () => {
    assert.match(run(`${deferredEnd}
    manager.playbackRequested = false
    manager.handleAudioInterruption(began: false, shouldResume: true)
    precondition(manager.pendingVideoEnd && manager.playbackRequestID == 1)
    manager.player?.play()
    `), /three background videos finished exactly once/);
});

test('cancelled sessions cannot be revived by an interruption end', () => {
    assert.match(run(`${deferredEnd}
    manager.cancelRecovery()
    manager.handleAudioInterruption(began: false, shouldResume: true)
    precondition(!manager.pendingVideoEnd && manager.playbackRequestID == 1)
    print("cancelled continuation stayed cancelled")
    exit(0)
    `), /cancelled continuation stayed cancelled/);
});

test('PiP exit, disabled continuation and quick settings prevent deferred navigation', () => {
    for (const disable of [
        'manager.isPiPActive = false',
        'AppDefaults.shared.pipAutoPlayNextVideo = false',
        'manager.coordinator?.isArticleQuickSettingsPresented = true'
    ]) {
        assert.match(run(`${deferredEnd}
        ${disable}
        manager.handleAudioInterruption(began: false, shouldResume: true)
        precondition(manager.finished && !manager.pendingVideoEnd && manager.playbackRequestID == 1)
        print("ineligible continuation finished without navigation")
        exit(0)
        `), /ineligible continuation finished without navigation/);
    }
});

test('resuming recovery preserves retry limits and accumulated waiting', () => {
    assert.match(run(`
    var state = VideoPlaybackRecovery()
    state.startAttempt(now: 0)
    precondition(state.retryDelay() == 1)
    state.suspend()
    state.resume(now: 100, mediaTime: 10)
    precondition(!state.isSuspended && state.retries == 1 && state.recoveryWait == 1)
    precondition(state.sample(now: 101, mediaTime: 11, playing: true, waiting: false) == .progress)
    precondition(state.retryDelay() == 3)
    precondition(state.retryDelay() == nil)
    print("recovery budget preserved")
    exit(0)
    `), /recovery budget preserved/);
});
