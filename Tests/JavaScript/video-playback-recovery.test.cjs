const assert = require('node:assert/strict');
const { readFileSync, mkdtempSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const http = require('node:http');
const { test } = require('node:test');

const source = readFileSync(resolve(__dirname, '../../iOS/Article/VideoPlayerManager.swift'), 'utf8');
const policy = source.slice(source.indexOf('nonisolated struct VideoPlaybackRecovery'), source.indexOf('// MARK: - AVPlayerViewControllerDelegate'));

test('production recovery policy bounds retries, deadlines, pauses and cumulative waiting', () => {
    const directory = mkdtempSync(join(tmpdir(), 'nnw-recovery-policy-'));
    try {
        const file = join(directory, 'main.swift');
        writeFileSync(file, `import Foundation
${policy}
var state = VideoPlaybackRecovery()
state.startAttempt(now: 0)
for second in 1..<15 {
    precondition(state.sample(now: Double(second), mediaTime: 0, playing: false, waiting: true) == .none)
}
precondition(state.sample(now: 15, mediaTime: 0, playing: false, waiting: true) == .timeout)
precondition(state.retryDelay() == 1)
state.startAttempt(now: 16)
precondition(state.retryDelay() == 3)
state.startAttempt(now: 19)
precondition(state.retryDelay() == nil)
state = VideoPlaybackRecovery()
state.startAttempt(now: 0)
for second in 1...100 {
    precondition(state.sample(now: Double(second), mediaTime: 0, playing: false, waiting: false) == .none)
}
precondition(state.recoveryWait == 0)
precondition(state.sample(now: 101, mediaTime: 200, playing: true, waiting: false) == .none)
state.suspend()
precondition(state.retryDelay() == nil)
precondition(state.sample(now: 500, mediaTime: 200, playing: false, waiting: true) == .none)
precondition(state.recoveryWait == 0)
state = VideoPlaybackRecovery()
state.startAttempt(now: 0)
for second in 1...5 {
    let sample = state.sample(now: Double(second), mediaTime: Double(second), playing: true, waiting: false)
    precondition(sample == (second == 5 ? .healthy : .progress))
}
for second in 6..<25 {
    precondition(state.sample(now: Double(second), mediaTime: 5, playing: false, waiting: true) == .none)
}
precondition(state.sample(now: 25, mediaTime: 5, playing: false, waiting: true) == .timeout)
state = VideoPlaybackRecovery()
state.startAttempt(now: 0)
var now: Double = 0
var position: Double = 0
for _ in 0..<6 {
    for _ in 0..<10 {
        now += 1
        _ = state.sample(now: now, mediaTime: position, playing: false, waiting: true)
    }
    now += 1
    position += 1
    _ = state.sample(now: now, mediaTime: position, playing: true, waiting: false)
}
precondition(state.recoveryWait == 60 && state.retryDelay() == nil)
print("policy passed")
`);
        assert.match(execFileSync('swift', [file], { encoding: 'utf8', timeout: 120000 }), /policy passed/);
    } finally { rmSync(directory, { recursive: true, force: true }); }
});

function method(signature) {
    const start = source.indexOf(signature);
    assert.notEqual(start, -1, signature);
    const body = source.indexOf('{', start);
    let depth = 0;
    for (let end = body; end < source.length; end++) {
        if (source[end] === '{') depth++;
        if (source[end] === '}' && --depth === 0) return source.slice(start, end + 1).replace(/^private /, '');
    }
    throw new Error('Unterminated method');
}

test('production failure transitions skip once, preserve unread candidates, and stop offline or after three failures', () => {
    const directory = mkdtempSync(join(tmpdir(), 'nnw-recovery-transition-'));
    try {
        const file = join(directory, 'main.swift');
        writeFileSync(file, `
import Foundation
import AVFoundation
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
    enum Animation { case navigation, scroll }
    func selectArticle(_ article: Article, animations: [Animation]) { currentArticle = article; article.read = true }
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
struct AppDelegate { func resumeDatabaseProcessingIfNecessary() {} }
let appDelegate = AppDelegate()
enum StatusKey { case read }
func markArticles(_ articles: Set<Article>, statusKey: StatusKey, flag: Bool) { articles.forEach { $0.read = flag } }
enum ArticleMediaLog {
    enum Level { case warning, info }
    static func log(_ level: Level, operation: String, message: String) {}
}
@MainActor final class Harness {
    var player: AVPlayer? = AVPlayer()
    var coordinator: SceneCoordinator? = SceneCoordinator()
    var playbackArticles = [Article("A"), Article("B"), Article("C"), Article("D")]
    var playbackIndex: Int?
    var currentArticleID: String?
    var pendingPlaybackArticle: Article?
    var playbackURL: URL?
    var playbackSessionID = UUID()
    var playbackRequestID = 0
    var recovery = VideoPlaybackRecovery()
    var consecutiveFailures = 0
    var attemptResolved = false
    var playbackRequested = true
    var ignoredPauseRequestID: Int?
    var resumePosition: Double = 0
    var retryTask: Task<Void, Never>?
    var canRecoverPlayback = true
    var finished = false
    func installPlaybackItem(_ item: AVPlayerItem, restoring position: Double = 0) {
        retryTask?.cancel()
        retryTask = nil
        playbackRequestID += 1
        attemptResolved = false
        recovery.startAttempt(now: 0)
        player?.replaceCurrentItem(with: item)
    }
    func requestPlayback(for item: AVPlayerItem) { playbackRequested = true }
    func suspendRecovery(reason: String) { retryTask?.cancel(); retryTask = nil; recovery.suspend() }
    func finishPlaybackSession() { finished = true }
    static func extractFirstVideoURL(from html: String?) -> URL? { URL(string: "http://127.0.0.1:1/test.mp4") }
    ${method('static func isCurrentPlaybackItem(')}
    ${method('private func handlePlaybackFailure(')}
    ${method('private func nextArticleForPlayback(')}
    ${method('private func startNextVideo(')}
    ${method('private func commitPlaybackProgress(')}
    func exhaustCurrent() -> AVPlayerItem {
        precondition(recovery.retryDelay() == 1)
        precondition(recovery.retryDelay() == 3)
        return player!.currentItem!
    }
}
Task { @MainActor in
    let manager = Harness()
    let b = manager.playbackArticles[1]
    let c = manager.playbackArticles[2]
    manager.startNextVideo(b, url: Harness.extractFirstVideoURL(from: b.body)!)
    let failed = manager.exhaustCurrent()
    manager.handlePlaybackFailure(failed, reason: "test")
    precondition(manager.currentArticleID == "C" && manager.consecutiveFailures == 1)
    precondition(!b.read && !c.read && manager.coordinator?.currentArticle == nil)
    manager.handlePlaybackFailure(failed, reason: "duplicate-old-notification")
    precondition(manager.currentArticleID == "C" && manager.consecutiveFailures == 1)
    manager.commitPlaybackProgress()
    precondition(c.read && !b.read && manager.coordinator?.currentArticle === c)
    manager.commitPlaybackProgress()
    let limit = Harness()
    limit.startNextVideo(limit.playbackArticles[0], url: Harness.extractFirstVideoURL(from: "video")!)
    for _ in 0..<3 {
        let item = limit.exhaustCurrent()
        limit.handlePlaybackFailure(item, reason: "test")
    }
    precondition(limit.currentArticleID == "C" && limit.consecutiveFailures == 3)
    precondition(limit.recovery.isSuspended && limit.playbackArticles.allSatisfy { !$0.read })
    let offline = Harness()
    offline.startNextVideo(offline.playbackArticles[0], url: Harness.extractFirstVideoURL(from: "video")!)
    NetworkMonitor.shared.isConnected = false
    offline.handlePlaybackFailure(offline.player!.currentItem!, reason: "offline")
    precondition(offline.currentArticleID == "A" && offline.recovery.isSuspended && offline.recovery.retries == 0)
    NetworkMonitor.shared.isConnected = true
    let disabled = Harness()
    disabled.startNextVideo(disabled.playbackArticles[0], url: Harness.extractFirstVideoURL(from: "video")!)
    disabled.canRecoverPlayback = false
    disabled.handlePlaybackFailure(disabled.player!.currentItem!, reason: "disabled")
    precondition(disabled.currentArticleID == "A" && !disabled.attemptResolved && disabled.recovery.retries == 0)
    print("transition checks passed")
    exit(0)
}
dispatchMain()
`);
        assert.match(execFileSync('swift', [file], { encoding: 'utf8', timeout: 120000 }), /transition checks passed/);
    } finally { rmSync(directory, { recursive: true, force: true }); }
});

test('real AVPlayer fails on local HTTP errors and recovers with a fresh item at the same URL', { timeout: 90000 }, async () => {
    const video = readFileSync(resolve(__dirname, '../NetNewsWire-iOSTests/Resources/video-preview.mp4'));
    let failing = true;
    const server = http.createServer((request, response) => {
        if (request.url === '/recover') {
            failing = false;
            response.end('ok');
            return;
        }
        if (failing) {
            response.writeHead(404, { 'Content-Type': 'text/plain' });
            response.end('missing');
            return;
        }
        const range = /bytes=(\d+)-(\d*)/.exec(request.headers.range || '');
        const start = range ? Number(range[1]) : 0;
        const end = range && range[2] ? Math.min(Number(range[2]), video.length - 1) : video.length - 1;
        if (start > end) { response.writeHead(416); response.end(); return; }
        const headers = { 'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes', 'Content-Length': end - start + 1 };
        if (range) headers['Content-Range'] = `bytes ${start}-${end}/${video.length}`;
        response.writeHead(range ? 206 : 200, headers);
        response.end(video.subarray(start, end + 1));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    const script = `
import Foundation
import AVFoundation
import Darwin
${policy}
Task { try? await Task.sleep(for: .seconds(30)); print("timeout"); exit(2) }
Task { @MainActor in
    let url = URL(string: "${base}/video.mp4")!
    let first = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: first)
    player.isMuted = true
    let ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: first, queue: .main) { _ in
        print("unexpected normal end")
        exit(3)
    }
    player.play()
    for _ in 0..<100 {
        if first.status == .failed { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    precondition(first.status == .failed)
    print("HTTP 404 caused failed status, not normal end")
    var recovery = VideoPlaybackRecovery()
    recovery.startAttempt(now: 0)
    precondition(recovery.retryDelay() == 1)
    _ = try await URLSession.shared.data(from: URL(string: "${base}/recover")!)
    let second = AVPlayerItem(asset: AVURLAsset(url: url))
    player.replaceCurrentItem(with: second)
    player.play()
    for _ in 0..<100 {
        if second.status == .readyToPlay && second.currentTime().seconds > 0 { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    precondition(second.status == .readyToPlay && second.currentTime().seconds > 0)
    NotificationCenter.default.removeObserver(ended)
    player.pause()
    print("fresh item recovered and advanced playback")
    exit(0)
}
dispatchMain()
`;
    try {
        const output = await new Promise((resolve, reject) => {
            const child = spawn('swift', ['-'], { stdio: ['pipe', 'pipe', 'pipe'] });
            let stdout = '', stderr = '';
            const timeout = setTimeout(() => child.kill('SIGKILL'), 60000);
            child.stdout.on('data', data => { stdout += data; });
            child.stderr.on('data', data => { stderr += data; });
            child.on('error', reject);
            child.on('close', code => {
                clearTimeout(timeout);
                if (code === 0) resolve(stdout);
                else reject(new Error(`Swift exit ${code}\n${stdout}\n${stderr}`));
            });
            child.stdin.end(script);
        });
        assert.match(output, /HTTP 404 caused failed status/);
        assert.match(output, /fresh item recovered and advanced playback/);
    } finally {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
    }
});
