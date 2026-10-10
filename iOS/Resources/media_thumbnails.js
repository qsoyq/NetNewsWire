(() => {
    "use strict";
    let enabled = false;
    let active = true;
    let nativeVideo = false;
    let labels = {};
    let strip = null;
    let observer = null;
    let timer = null;
    let entries = new Map();
    const rootSelector = "#bodyContainer,.articleBody,.article-body";

    function originalURL(value) {
        if (/^nnwvideocache:/i.test(value)) {
            try { return new URL(value).searchParams.get("url") || ""; } catch (_) { return ""; }
        }
        return value || "";
    }

    function source(element) {
        return element.currentSrc || element.src || element.querySelector("source[src]")?.src || "";
    }

    function collect() {
        const seen = new Set();
        const result = [];
        document.querySelectorAll(`${rootSelector.split(",").map(root => `${root} img,${root} video`).join(",")}`).forEach(element => {
            if (element.closest("[data-nnw-media-thumbnails],header,.headerContainer,.header-container,[hidden],[aria-hidden='true']") ||
                element.id === "nnwImageIcon" || element.classList.contains("activityIndicator") ||
                element.classList.contains("nnwAnimatedGIF")) return;
            const video = element.tagName === "VIDEO";
            if (!video && ((element.width > 0 && element.width <= 2) ||
                (element.naturalWidth > 0 && element.naturalWidth <= 2))) return;
            const url = originalURL(source(element));
            if (!/^(https?:|data:image\/)/i.test(url) || (video && !/^https?:/i.test(url))) return;
            const key = `${video ? "video" : "image"}:${url}`;
            if (seen.has(key)) return;
            seen.add(key);
            result.push({ key, element, url, video });
        });
        return result;
    }

    function installStyle() {
        if (document.getElementById("nnw-media-thumbnails-style")) return;
        const style = document.createElement("style");
        style.id = "nnw-media-thumbnails-style";
        style.textContent = `
            [data-nnw-media-thumbnails] {
                display:flex!important; gap:8px!important; overflow-x:auto!important;
                max-width:100%!important; min-width:0!important; box-sizing:border-box!important;
                padding:4px 0 12px!important; margin:12px 0 16px!important;
                overscroll-behavior-x:contain; -webkit-overflow-scrolling:touch;
                scrollbar-width:none; touch-action:pan-x pan-y;
            }
            [data-nnw-media-thumbnails]::-webkit-scrollbar { display:none; }
            [data-nnw-media-thumbnails] button {
                appearance:none!important; position:relative!important; display:block!important;
                flex:0 0 112px!important; width:112px!important; height:88px!important;
                min-height:88px!important; padding:0!important; margin:0!important;
                border:1px solid rgba(128,128,128,.25)!important; border-radius:8px!important;
                background-color:rgba(128,128,128,.12)!important;
                background-size:cover!important; background-position:center!important;
                color:inherit!important; overflow:hidden!important; cursor:pointer;
                -webkit-tap-highlight-color:transparent;
            }
            [data-nnw-media-thumbnails] button:active { opacity:.7; }
            [data-nnw-media-thumbnails] button:focus-visible { outline:2px solid currentColor; outline-offset:2px; }
            [data-nnw-media-thumbnails] .nnw-thumbnail-play {
                position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
            }
            [data-nnw-media-thumbnails] .nnw-thumbnail-play::after {
                content:'▶'; display:flex; align-items:center; justify-content:center;
                width:32px; height:32px; border-radius:50%; background:rgba(0,0,0,.6);
                color:white; font:16px system-ui; padding-left:2px; box-sizing:border-box;
            }
        `;
        document.head.appendChild(style);
    }

    function activate(entry) {
        if (!enabled || !active || !entry.element.isConnected) return;
        if (entry.video) {
            if (nativeVideo) {
                entry.element.pause();
                window.webkit.messageHandlers.nativeVideoPlay.postMessage(entry.url);
            } else {
                const video = entry.element;
                // Keep fullscreen entry in the user's tap, without waiting for a native round trip.
                try {
                    const playback = video.play();
                    if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
                    else if (video.requestFullscreen) video.requestFullscreen().catch(() => {});
                    playback?.catch(() => {});
                } catch (_) { /* The original inline controls remain available. */ }
            }
            return;
        }
        const rect = entry.button.getBoundingClientRect();
        window.webkit.messageHandlers.imageWasClicked.postMessage(JSON.stringify({
            x: rect.x, y: rect.y, width: rect.width, height: rect.height,
            imageTitle: entry.element.title || entry.element.alt || "",
            imageURL: entry.url, resourceURL: entry.url
        }));
    }

    function refresh() {
        timer = null;
        if (!enabled || !active) return;
        const items = collect();
        const root = document.querySelector(rootSelector);
        if (!root || !items.length) {
            strip?.remove();
            strip = null;
            entries.clear();
            return;
        }
        installStyle();
        if (!strip) {
            strip = document.createElement("div");
            strip.setAttribute("data-nnw-media-thumbnails", "");
            strip.setAttribute("translate", "no");
            strip.setAttribute("role", "group");
            strip.setAttribute("aria-label", labels.media);
            root.before(strip);
        }
        const next = new Map();
        items.forEach((item, index) => {
            const entry = entries.get(item.key) || { button: document.createElement("button") };
            Object.assign(entry, item);
            const button = entry.button;
            button.type = "button";
            button.setAttribute("aria-label", `${item.video ? labels.video : labels.image} ${index + 1}`);
            button.onclick = event => { event.preventDefault(); event.stopPropagation(); activate(entry); };
            const preview = item.video ? item.element.poster : source(item.element);
            if (entry.preview !== preview) {
                entry.preview = preview;
                button.style.backgroundImage = preview ? `url(${JSON.stringify(preview)})` : "none";
            }
            if (item.video && !button.firstChild) {
                const play = document.createElement("span");
                play.className = "nnw-thumbnail-play";
                play.setAttribute("aria-hidden", "true");
                button.appendChild(play);
            }
            if (strip.children[index] !== button) strip.insertBefore(button, strip.children[index] || null);
            next.set(item.key, entry);
        });
        entries.forEach((entry, key) => { if (!next.has(key)) entry.button.remove(); });
        entries = next;
    }

    function schedule(event) {
        if (event && !event.target.closest?.(rootSelector)) return;
        if (enabled && active && timer === null) timer = setTimeout(refresh, 60);
    }

    function configure(value, useNativeVideo, localizedLabels) {
        nativeVideo = Boolean(useNativeVideo);
        labels = localizedLabels;
        if (enabled === Boolean(value)) { if (enabled) refresh(); return; }
        enabled = Boolean(value);
        if (!enabled) {
            observer?.disconnect();
            observer = null;
            clearTimeout(timer);
            timer = null;
            document.removeEventListener("load", schedule, true);
            document.removeEventListener("error", schedule, true);
            strip?.remove();
            strip = null;
            entries.clear();
            return;
        }
        observer = new MutationObserver(records => {
            if (records.some(record => !record.target.closest?.("[data-nnw-media-thumbnails]") &&
                (record.target.closest?.(rootSelector) || Array.from(record.addedNodes).some(node =>
                    node.nodeType === 1 && (node.matches(rootSelector) || node.querySelector(rootSelector)))))) schedule();
        });
        observer.observe(document.body, { childList: true, subtree: true, attributes: true,
            attributeFilter: ["src", "srcset", "poster", "hidden", "class"] });
        document.addEventListener("load", schedule, true);
        document.addEventListener("error", schedule, true);
        refresh();
    }

    function setActive(value) {
        active = Boolean(value);
        if (!active) { clearTimeout(timer); timer = null; }
        else if (enabled) refresh();
    }

    window.nnwMediaThumbnails = { configure, setActive };
})();
