const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');
const script = readFileSync(resolve(__dirname, '../../iOS/Resources/video_preview.js'), 'utf8');

function video(src, { poster = '', gif = false, child = '', currentSrc = '' } = {}) {
    const attributes = new Map(poster ? [['poster', poster]] : []);
    return {
        src, currentSrc, isConnected: true,
        classList: { contains: value => gif && value === 'nnwAnimatedGIF' },
        querySelector: () => child ? { src: child } : null,
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
