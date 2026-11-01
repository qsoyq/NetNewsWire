(() => {
    "use strict";
    let documentID = "";
    let enabled = false;
    let preloadEnabled = false;
    let sequence = 0;
    const entries = new Map();
    const identities = new WeakMap();
    const preloads = new Map();

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

    function eligibleForPreload(video) {
        return !video.classList.contains("nnwAnimatedGIF");
    }

    function updatePreload() {
        document.querySelectorAll("video").forEach(video => {
            if (!eligibleForPreload(video) && !preloads.has(video)) return;
            if (preloadEnabled) {
                if (!preloads.has(video)) {
                    preloads.set(video, { had: video.hasAttribute("preload"), value: video.getAttribute("preload") });
                }
                video.setAttribute("preload", "auto");
            } else if (preloads.has(video)) {
                const original = preloads.get(video);
                if (original.had) video.setAttribute("preload", original.value ?? "");
                else video.removeAttribute("preload");
                preloads.delete(video);
            }
        });
    }

    function configure(id, value, preload) {
        const nextEnabled = Boolean(value);
        const nextPreload = Boolean(preload);
        if (id === documentID && enabled === nextEnabled && preloadEnabled === nextPreload) return;
        if (id !== documentID || enabled !== nextEnabled) clear();
        documentID = id;
        enabled = nextEnabled;
        preloadEnabled = nextPreload;
        updatePreload();
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
