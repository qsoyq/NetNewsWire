const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, readFileSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { test } = require('node:test');

// Execute the production Swift transition methods on the host. UIKit/AVKit
// boundaries are small fakes so no iOS simulator or device is required.
function method(path, signature) {
	const source = readFileSync(resolve(__dirname, '../..', path), 'utf8');
	const start = source.indexOf(signature);
	assert.notEqual(start, -1, signature);
	let depth = 0;
	const body = source.indexOf('{', start);
	for (let end = body; end < source.length; end++) {
		if (source[end] === '{') depth++;
		if (source[end] === '}' && --depth === 0) {
			return source.slice(start, end + 1).replace(/^private /, '');
		}
	}
	throw new Error('Unterminated Swift method');
}

test('native session cleanup precedes dismissal completion and current-page playback resumes safely', () => {
	const finish = method('iOS/Article/VideoPlayerManager.swift', 'private func finishPlaybackSession(');
	const resume = method('iOS/Article/WebViewController.swift', 'func resumeNativeVideoAfterPageTransition(');
	const managerSource = readFileSync(resolve(__dirname, '../../iOS/Article/VideoPlayerManager.swift'), 'utf8');
	const dismissalSignature = managerSource.match(/if [^\n]*!isRestoringUserInterface \{/)[0];
	const dismissalGuard = method('iOS/Article/VideoPlayerManager.swift', dismissalSignature);
	const directory = mkdtempSync(join(tmpdir(), 'nnw-video-transition-'));
	try {
		const script = join(directory, 'main.swift');
		writeFileSync(script, `
final class Player {
    var currentItem: Int? = 1
    var paused = false
    func pause() { paused = true }
    func replaceCurrentItem(with item: Int?) { currentItem = item }
}
final class PlayerController {
    var presentingViewController: Int? = 1
    var completion: (() -> Void)?
    var dismissed = false
    func dismiss(animated: Bool, completion: (() -> Void)?) {
        dismissed = true
        self.completion = completion
    }
}
final class Manager {
    var player: Player? = Player()
    var playerViewController: PlayerController? = PlayerController()
    var currentArticleID: String? = "first"
    var playbackArticles = ["first", "second"]
    var isPiPActive = false
    var isRestoringUserInterface = false
    var observing = true
    func logPlaybackDiagnostics(for item: Int, event: String) {}
    func removeEndObserver() { observing = false }
    ${finish}
    func didDismiss(_ playerViewController: PlayerController) { ${dismissalGuard} }
}
let manager = Manager()
let oldController = manager.playerViewController!
var navigations = 0
manager.finishPlaybackSession {
    precondition(manager.player?.currentItem == nil)
    precondition(manager.currentArticleID == nil && manager.playbackArticles.isEmpty)
    precondition(!manager.observing && manager.playerViewController == nil)
    navigations += 1
    // Model the next page immediately starting another session.
    manager.player?.replaceCurrentItem(with: 2)
    manager.currentArticleID = "second"
    manager.playerViewController = PlayerController()
}
precondition(navigations == 0 && oldController.dismissed)
precondition(manager.player?.paused == true && manager.player?.currentItem == nil)
oldController.completion?()
precondition(navigations == 1 && manager.player?.currentItem == 2)
precondition(manager.currentArticleID == "second" && manager.playerViewController != nil)
manager.didDismiss(oldController)
precondition(manager.player?.currentItem == 2 && manager.currentArticleID == "second")
let noPresentation = Manager()
noPresentation.playerViewController = nil
var immediate = false
noPresentation.finishPlaybackSession { immediate = true }
precondition(immediate && noPresentation.player?.currentItem == nil)
let pip = Manager()
pip.isPiPActive = true
let pipController = pip.playerViewController!
pip.finishPlaybackSession()
precondition(!pipController.dismissed && pip.playerViewController === pipController)

final class View { var window: Int? = 1 }
final class ArticleViewController {
    var current = true
    func isCurrentWebViewController(_ controller: WebController) -> Bool { current }
}
final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
}
final class VideoPlayerManager {
    static let shared = VideoPlayerManager()
    var isPiPActive = false
}
final class WebViewPiPManager {
    static let shared = WebViewPiPManager()
    var isPiPActive = false
}
final class PreviewController {
    var active = false
    func setActive(_ value: Bool) { active = value }
}
final class ArticlePrefetcher {
    static let shared = ArticlePrefetcher()
    var requests = 0
    func prefetchNextArticle(after article: String?, coordinator: Int) {
        precondition(article != nil && coordinator == 1)
        requests += 1
    }
}
final class ThumbnailWebView { var thumbnailsActive = false }
enum ArticleMediaThumbnails {
    static func configure(_ webView: ThumbnailWebView, active: Bool) {
        webView.thumbnailsActive = active
    }
}
final class WebController {
    var webView: ThumbnailWebView? = ThumbnailWebView()
    var viewIfLoaded: View? = View()
    var delegate: Any? = ArticleViewController()
    var presentedViewController: Int?
    var isBeingDismissed = false
    var videoPresentationEnabled = false
    let videoPreviewController = PreviewController()
    var article: String? = "first"
    var coordinator = 1
    var autoplayAttempts = 0
    func startNativeVideoDirectly() { autoplayAttempts += 1 }
    ${resume}
}
let page = WebController()
page.resumeNativeVideoAfterPageTransition()
precondition(page.videoPresentationEnabled && page.autoplayAttempts == 1)
precondition(page.videoPreviewController.active && ArticlePrefetcher.shared.requests == 1)
precondition(page.webView?.thumbnailsActive == true)
for blocker in 0..<7 {
    let page = WebController()
    switch blocker {
    case 0: page.viewIfLoaded?.window = nil
    case 1: (page.delegate as! ArticleViewController).current = false
    case 2: page.presentedViewController = 1
    case 3: page.isBeingDismissed = true
    case 4: UIApplication.shared.applicationState = .background
    case 5: VideoPlayerManager.shared.isPiPActive = true
    default: WebViewPiPManager.shared.isPiPActive = true
    }
    page.resumeNativeVideoAfterPageTransition()
    precondition(!page.videoPresentationEnabled && page.autoplayAttempts == 0)
    precondition(!page.videoPreviewController.active && ArticlePrefetcher.shared.requests == 1)
    precondition(page.webView?.thumbnailsActive == false)
    UIApplication.shared.applicationState = .active
    VideoPlayerManager.shared.isPiPActive = false
    WebViewPiPManager.shared.isPiPActive = false
}
print("Native video transition checks passed")
`);
		const output = execFileSync('swift', [script], { encoding: 'utf8', timeout: 120000 });
		assert.match(output, /Native video transition checks passed/);
	} finally {
		rmSync(directory, { recursive: true, force: true });
	}
});
