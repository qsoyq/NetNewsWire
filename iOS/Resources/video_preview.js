(() => {
    "use strict";
    let documentID = "";
    let enabled = false;
    let sequence = 0;
    const entries = new Map();
    const identities = new WeakMap();

    function source(video) {
        let value = video.src || video.querySelector("source[src]")?.src || video.currentSrc || "";
        if (/^nnwvideocache:/i.test(value)) {
            try { value = new URL(value).searchParams.get("url") || ""; } catch (_) { return ""; }
        }
        return /^https?:/i.test(value) ? value : "";
    }

    function clear() {
        entries.forEach(entry => {
            if (entry.poster && entry.element.getAttribute("poster") === entry.poster) {
                entry.element.removeAttribute("poster");
            }
        });
        entries.clear();
    }

    function configure(id, value) {
        if (id === documentID && enabled === Boolean(value)) return;
        clear();
        documentID = id;
        enabled = Boolean(value);
    }

    function collect(id) {
        if (!enabled || id !== documentID) return "[]";
        const result = [];
        document.querySelectorAll("video").forEach(video => {
            if (video.classList.contains("nnwAnimatedGIF") || (video.getAttribute("poster") || "").trim()) return;
            const url = source(video);
            if (!url) return;
            let key = identities.get(video);
            if (!key) { key = String(++sequence); identities.set(video, key); }
            entries.set(key, { element: video, url, poster: null });
            result.push({ id: key, url });
        });
        return JSON.stringify(result);
    }

    function apply(id, key, url, poster) {
        const entry = entries.get(key);
        if (!enabled || id !== documentID || !entry || !entry.element.isConnected ||
            entry.url !== url || source(entry.element) !== url ||
            entry.element.classList.contains("nnwAnimatedGIF") ||
            (entry.element.getAttribute("poster") || "").trim() || !poster.startsWith("data:image/jpeg;base64,")) return false;
        entry.poster = poster;
        entry.element.setAttribute("poster", poster);
        return true;
    }

    window.nnwVideoPreview = { configure, collect, apply };
})();
