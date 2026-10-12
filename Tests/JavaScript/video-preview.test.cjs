const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');
const script = readFileSync(resolve(__dirname, '../../iOS/Resources/video_preview.js'), 'utf8');

function video(src, { poster = '', gif = false, child = '', currentSrc = '', preload = null } = {}) {
    const attributes = new Map(poster ? [['poster', poster]] : []);
    if (preload !== null) attributes.set('preload', preload);
    const listeners = new Map();
    return {
        src, currentSrc, isConnected: true, currentTime: 0, paused: true, listeners,
        classList: { contains: value => gif && value === 'nnwAnimatedGIF' },
        querySelector: () => child ? { src: child } : null,
        hasAttribute: name => attributes.has(name),
        addEventListener: (name, listener) => listeners.set(name, listener),
        removeEventListener: name => listeners.delete(name),
        getAttribute: name => attributes.get(name) ?? null,
        setAttribute: (name, value) => attributes.set(name, value),
        removeAttribute: name => attributes.delete(name),
        play() { throw new Error('Preview must not play video'); }
    };
}
function page(videos) {
    const context = vm.createContext({ URL, window: {}, document: { querySelectorAll: () => videos } });
    vm.runInContext(script, context);
    return context.window.nnwVideoPreview;
}
const poster = 'data:image/jpeg;base64,ZmFrZQ==';

test('disabled performs no collection; only missing posters are eligible', () => {
    const videos = [video('https://example.test/a.mp4'), video('https://example.test/b.mp4', { poster: 'cover.jpg' }), video('https://example.test/c.mp4', { gif: true }), video('blob:abc')];
    const api = page(videos);
    assert.deepEqual(JSON.parse(api.collect('first')), []);
    api.configure('first', true);
    assert.deepEqual(JSON.parse(api.collect('first')).map(item => item.url), ['https://example.test/a.mp4']);
});
test('cached source and source child resolve without changing playback addresses', () => {
    const original = 'https://example.test/video.mp4?a=1&b=2';
    const cached = 'nnwvideocache://cache?url=' + encodeURIComponent(original);
    const videos = [video(cached), video('', { child: original })];
    const api = page(videos);
    api.configure('first', true);
    const items = JSON.parse(api.collect('first'));
    assert.equal(items.length, 2);
    for (const item of items) assert.equal(item.url, original);
    assert.equal(api.apply('first', items[0].id, original, poster), true);
    assert.equal(videos[0].src, cached);
});
test('late results cannot apply after navigation, disconnection, or source replacement', () => {
    for (const action of ['navigate', 'disconnect', 'replace']) {
        const element = video('https://example.test/video.mp4');
        const api = page([element]);
        api.configure('first', true);
        const item = JSON.parse(api.collect('first'))[0];
        if (action === 'navigate') api.configure('second', true);
        if (action === 'disconnect') element.isConnected = false;
        if (action === 'replace') element.src = 'https://example.test/other.mp4';
        assert.equal(api.apply('first', item.id, item.url, poster), false);
        assert.equal(element.getAttribute('poster'), null);
    }
});
test('disabling removes generated previews and rejects pending results', () => {
    const element = video('https://example.test/video.mp4');
    const api = page([element]);
    api.configure('first', true);
    const item = JSON.parse(api.collect('first'))[0];
    api.apply('first', item.id, item.url, poster);
    api.configure('second', false);
    assert.equal(element.getAttribute('poster'), null);
    assert.equal(api.apply('first', item.id, item.url, poster), false);
});
test('re-activating the same document preserves generated preview', () => {
    const element = video('https://example.test/video.mp4');
    const api = page([element]);
    api.configure('first', true);
    const item = JSON.parse(api.collect('first'))[0];
    api.apply('first', item.id, item.url, poster);
    api.configure('first', true);
    assert.equal(element.getAttribute('poster'), poster);
});
test('a feed poster added after collection is never replaced or removed', () => {
    const element = video('https://example.test/video.mp4');
    const api = page([element]);
    api.configure('first', true);
    const item = JSON.parse(api.collect('first'))[0];
    element.setAttribute('poster', 'new-cover.jpg');
    assert.equal(api.apply('first', item.id, item.url, poster), false);
    api.configure('first', false);
    assert.equal(element.getAttribute('poster'), 'new-cover.jpg');
});
test('distinct videos retain distinct identities when DOM order changes', () => {
    const videos = [video('https://example.test/a.mp4'), video('https://example.test/b.mp4')];
    const api = page(videos);
    api.configure('first', true);
    const items = JSON.parse(api.collect('first'));
    videos.reverse();
    assert.equal(api.apply('first', items[0].id, items[0].url, poster), true);
    assert.equal(videos[1].getAttribute('poster'), poster);
    assert.equal(videos[0].getAttribute('poster'), null);
});

test('preload toggles only non-GIF videos and restores original values', () => {
    const missing = video('https://example.test/a.mp4');
    const none = video('https://example.test/b.mp4', { preload: 'none' });
    const gif = video('https://example.test/c.mp4', { gif: true });
    const api = page([missing, none, gif]);
    api.configure('first', false, true);
    assert.equal(missing.getAttribute('preload'), 'auto');
    assert.equal(none.getAttribute('preload'), 'auto');
    assert.equal(gif.getAttribute('preload'), null);
    api.configure('first', false, false);
    assert.equal(missing.getAttribute('preload'), null);
    assert.equal(none.getAttribute('preload'), 'none');
});
test('unavailable state is applied once, preserves layout hooks, and can be retried', () => {
    const element = video('https://example.test/video.mp4');
    element.setAttribute('controls', 'controls');
    element.play = () => { element.played = true; return Promise.resolve(); };
    const api = page([element]);
    api.configure('first', true, false);
    const item = JSON.parse(api.collect('first'))[0];
    assert.equal(api.markUnavailable('first', item.id, item.url, 'Video cannot be played'), true);
    assert.match(element.getAttribute('poster'), /^data:image\/svg\+xml/);
    assert.equal(element.getAttribute('aria-label'), 'Video cannot be played');
    assert.equal(element.hasAttribute('controls'), false);
    element.listeners.get('click')();
    assert.equal(element.getAttribute('poster'), null);
    assert.equal(element.hasAttribute('controls'), true);
    assert.equal(element.played, true);
});
test('late unavailable result cannot override playback, covers, navigation, or replacement', () => {
    for (const action of ['playing', 'poster', 'navigate', 'replace']) {
        const element = video('https://example.test/video.mp4');
        const api = page([element]);
        api.configure('first', true, false);
        const item = JSON.parse(api.collect('first'))[0];
        if (action === 'playing') { element.currentTime = 1; element.paused = false; }
        if (action === 'poster') element.setAttribute('poster', 'cover.jpg');
        if (action === 'navigate') api.configure('second', true, false);
        if (action === 'replace') element.src = 'https://example.test/other.mp4';
        assert.equal(api.markUnavailable('first', item.id, item.url, 'Video cannot be played'), false);
    }
});
