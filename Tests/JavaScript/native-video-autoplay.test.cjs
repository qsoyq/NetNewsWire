const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const source = readFileSync(process.env.NNW_VIDEO_SCRIPT || resolve(__dirname, '../../iOS/Resources/main_ios.js'), 'utf8');

function page({ src = 'https://example.test/video.mp4', currentSrc = '', sourceURL = '', gif = false } = {}) {
	const messages = [];
	const listeners = [];
	const video = {
		src, currentSrc, paused: false, readyState: 0, networkState: 2, error: null,
		classList: { contains: () => gif },
		querySelector: () => sourceURL ? { src: sourceURL } : null,
		addEventListener: (name, callback) => listeners.push(callback),
		pause() { this.paused = true; },
		play() { throw new Error('WebKit autoplay is denied'); }
	};
	const context = vm.createContext({
		URL,
		window: { addEventListener() {}, webkit: { messageHandlers: { nativeVideoPlay: { postMessage: url => messages.push(url) } } } },
		document: { querySelector: () => gif ? null : video, querySelectorAll: () => [video] }
	});
	vm.runInContext(source, context);
	return { context, video, listeners, messages, snapshot: () => vm.runInContext('nativeVideoAutoplaySource()', context) };
}

test('first open returns a native source before loading and without calling denied WebKit play', () => {
	const fixture = page();
	const snapshot = fixture.snapshot();
	assert.equal(snapshot.outcome, 'ready');
	assert.equal(snapshot.url, fixture.video.src);
	assert.equal(snapshot.readyState, 0);
	assert.equal(fixture.video.paused, true);
});

test('cached current source is resolved to original HTTPS URL', () => {
	const original = 'https://example.test/video.mp4?a=1&b=2';
	const fixture = page({ currentSrc: 'nnwvideocache://cache?url=' + encodeURIComponent(original) });
	assert.equal(fixture.snapshot().url, original);
});

test('source child works before currentSrc is populated', () => {
	const fixture = page({ src: '', sourceURL: 'https://example.test/child.mp4' });
	assert.equal(fixture.snapshot().url, 'https://example.test/child.mp4');
});

test('GIFs and unsupported sources never initiate native playback', () => {
	assert.equal(page({ gif: true }).snapshot().outcome, 'no-video');
	const fixture = page({ src: 'blob:https://example.test/123' });
	assert.equal(fixture.snapshot().outcome, 'unsupported-source');
	assert.equal(fixture.video.paused, false);
});

test('queued playing events do not duplicate direct autoplay; later manual playback still hands off', () => {
	const fixture = page();
	vm.runInContext('setupVideoAutoFullscreenNative(); setupVideoAutoFullscreenNative();', fixture.context);
	assert.equal(fixture.listeners.length, 1);
	fixture.snapshot();
	fixture.listeners[0]();
	assert.equal(fixture.messages.length, 0);
	fixture.video.paused = false;
	fixture.listeners[0]();
	assert.deepEqual(fixture.messages, ['https://example.test/video.mp4']);
});

test('media errors remain visible in the direct source diagnostics', () => {
	const fixture = page();
	fixture.video.error = { code: 4 };
	assert.equal(fixture.snapshot().errorCode, 4);
});
