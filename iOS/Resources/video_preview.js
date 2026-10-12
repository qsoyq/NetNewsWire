(() => {
    "use strict";
    let documentID = "";
    let enabled = false;
    let preloadEnabled = false;
    let sequence = 0;
    const entries = new Map();
    const identities = new WeakMap();
    const preloads = new Map();
    const unavailablePoster = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 540"><rect width="960" height="540" fill="#000"/>' +
        '<path d="M440 225v110l95-55z" fill="#9a9a9a"/>' +
        '<path d="M410 195l175 95M440 180l175 95" stroke="#9a9a9a" stroke-width="9" stroke-linecap="round" fill="none"/></svg>');

    function source(video) {
        let value = video.src || video.querySelector("source[src]")?.src || video.currentSrc || "";
        if (/^nnwvideocache:/i.test(value)) {
            try { value = new URL(value).searchParams.get("url") || ""; } catch (_) { return ""; }
        }
        return /^https?:/i.test(value) ? value : "";
    }

    function restoreUnavailable(entry) {
        if (!entry.unavailable) return;
        entry.element.removeEventListener("click", entry.handler);
        if (entry.hadControls) entry.element.setAttribute("controls", "controls");
        entry.element.removeAttribute("aria-label");
        entry.unavailable = false;
    }

    function clear() {
        entries.forEach(entry => {
            restoreUnavailable(entry);
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

    function markUnavailable(id, key, url, label) {
        const entry = entries.get(key);
        if (!enabled || id !== documentID || !entry || !entry.element.isConnected ||
            entry.url !== url || source(entry.element) !== url ||
            entry.element.classList.contains("nnwAnimatedGIF") ||
            (entry.element.getAttribute("poster") || "").trim() || entry.element.currentTime > 0 ||
            (!entry.element.paused && entry.element.paused !== undefined)) return false;
        const element = entry.element;
        entry.poster = unavailablePoster;
        entry.hadControls = element.hasAttribute("controls");
        entry.unavailable = true;
        entry.handler = () => {
            restoreUnavailable(entry);
            if (entry.poster && element.getAttribute("poster") === entry.poster) element.removeAttribute("poster");
            element.play?.()?.catch?.(() => {});
        };
        element.setAttribute("poster", unavailablePoster);
        element.removeAttribute("controls");
        element.setAttribute("aria-label", String(label || ""));
        element.addEventListener("click", entry.handler);
        return true;
    }

    window.nnwVideoPreview = { configure, collect, apply, markUnavailable };
})();
