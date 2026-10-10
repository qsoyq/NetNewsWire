(() => {
    "use strict";
    let enabled = false;
    let hideBodyMedia = false;
    const hiddenNodes = new Set();
    const linkLabels = new Set();
    const permittedVideos = new Set();
    const boundVideos = new WeakSet();
    const originalControls = new Map();
    const hiddenAttribute = "data-nnw-body-media-hidden";
    const saveAttribute = "data-nnw-body-media-saveable";
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

    function bodyMedia() {
        return Array.from(document.querySelectorAll(rootSelector.split(",").map(root => `${root} img,${root} video`).join(",")));
    }

    function restoreBodyLayout() {
        hiddenNodes.forEach(node => {
            node.removeAttribute(hiddenAttribute);
            node.removeAttribute(saveAttribute);
        });
        hiddenNodes.clear();
        linkLabels.forEach(node => node.remove());
        linkLabels.clear();
    }

    function markHidden(node) {
        node.setAttribute(hiddenAttribute, "");
        hiddenNodes.add(node);
    }

    function hasContent(node) {
        if (node.nodeType === Node.TEXT_NODE) return Boolean(node.textContent.trim());
        if (node.nodeType !== Node.ELEMENT_NODE) return false;
        if (node.hasAttribute(hiddenAttribute)) return false;
        if (["BR", "SOURCE"].includes(node.tagName)) return false;
        if (["A", "P", "DIV", "SPAN", "PICTURE", "FIGURE"].includes(node.tagName)) {
            return Array.from(node.childNodes).some(hasContent);
        }
        return true;
    }

    function applyBodyVisibility() {
        if (!hideBodyMedia) return;
        for (const element of bodyMedia()) {
            if (element.closest("header,.headerContainer,.header-container") || element.id === "nnwImageIcon") continue;
            if (permittedVideos.has(element) || element.webkitDisplayingFullscreen ||
                ["fullscreen", "picture-in-picture"].includes(element.webkitPresentationMode)) continue;
            const originallyVisible = element.getClientRects().length > 0 &&
                !element.closest("[hidden],[aria-hidden='true']") && getComputedStyle(element).visibility !== "hidden";
            if (originallyVisible) element.setAttribute(saveAttribute, "");
            markHidden(element);
            if (element.tagName === "VIDEO") element.pause();
        }
        // Preserve an image-only link's destination without retaining its image-sized box.
        for (const element of hiddenNodes) {
            if (!element.matches("img,video")) continue;
            const link = element.closest("a[href]");
            if (link && !Array.from(link.childNodes).some(hasContent)) {
                const label = document.createElement("span");
                label.textContent = labels.link || "Open Media Link";
                label.setAttribute("data-nnw-media-link-label", "");
                label.setAttribute("translate", "no");
                link.appendChild(label);
                linkLabels.add(label);
            }
        }
        // Collapse only media ancestors that now contain no text, captions or controls.
        for (const element of Array.from(hiddenNodes)) {
            let parent = element.parentElement;
            while (parent && !parent.matches(rootSelector) &&
                parent.matches("p,div,span,picture,figure,a") && !Array.from(parent.childNodes).some(hasContent)) {
                markHidden(parent);
                parent = parent.parentElement;
            }
        }
    }

    function guardHiddenPlayback(event) {
        const video = event.target;
        if (hideBodyMedia && video.matches?.("video") && video.closest(rootSelector) &&
            !permittedVideos.has(video) && !video.webkitDisplayingFullscreen &&
            !["fullscreen", "picture-in-picture"].includes(video.webkitPresentationMode)) {
            video.pause();
            event.stopImmediatePropagation();
        }
    }

    function revealVideo(video) {
        permittedVideos.add(video);
        if (!boundVideos.has(video)) {
            boundVideos.add(video);
            const conceal = () => {
                if (video.webkitPresentationMode === "picture-in-picture") return;
                permittedVideos.delete(video);
                if (originalControls.has(video)) {
                    video.controls = originalControls.get(video);
                    originalControls.delete(video);
                }
                schedule();
            };
            video.addEventListener("webkitendfullscreen", conceal);
            video.addEventListener("ended", conceal);
            video.addEventListener("fullscreenchange", () => {
                if (!document.fullscreenElement) conceal();
            });
        }
        refresh();
        // If fullscreen entry fails, the restored inline controls remain usable.
        if (!originalControls.has(video)) originalControls.set(video, video.controls);
        video.controls = true;
    }

    function collect() {
        const seen = new Set();
        const result = [];
        bodyMedia().forEach(element => {
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
            [data-nnw-body-media-hidden] { display:none!important; }
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
                if (hideBodyMedia) revealVideo(video);
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
            imageURL: entry.url, resourceURL: entry.url,
            images: Array.from(entries.values()).filter(item => !item.video).map(item => ({
                url: item.url, title: item.element.title || item.element.alt || ""
            }))
        }));
    }

    function refresh() {
        timer = null;
        observer?.disconnect();
        restoreBodyLayout();
        if (enabled || hideBodyMedia) installStyle();
        const items = enabled ? collect() : [];
        applyBodyVisibility();
        observe();
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
        if ((enabled || hideBodyMedia) && active && timer === null) timer = setTimeout(refresh, 60);
    }

    function configure(value, useNativeVideo, localizedLabels, hideMedia = false) {
        nativeVideo = Boolean(useNativeVideo);
        labels = localizedLabels;
        enabled = Boolean(value);
        hideBodyMedia = Boolean(hideMedia);
        if (!hideBodyMedia) {
            originalControls.forEach((controls, video) => { video.controls = controls; });
            originalControls.clear();
            permittedVideos.clear();
        }
        document.documentElement.toggleAttribute("data-nnw-hide-body-media", hideBodyMedia);
        if (!enabled && !hideBodyMedia) {
            observer?.disconnect();
            observer = null;
            clearTimeout(timer);
            timer = null;
            document.removeEventListener("load", schedule, true);
            document.removeEventListener("error", schedule, true);
            document.removeEventListener("play", guardHiddenPlayback, true);
            document.removeEventListener("playing", guardHiddenPlayback, true);
            restoreBodyLayout();
            permittedVideos.clear();
            strip?.remove();
            strip = null;
            entries.clear();
            return;
        }
        if (!observer) observer = new MutationObserver(records => {
            if (records.some(record => !record.target.closest?.("[data-nnw-media-thumbnails]") &&
                (record.target.closest?.(rootSelector) || Array.from(record.addedNodes).some(node =>
                    node.nodeType === 1 && (node.matches(rootSelector) || node.querySelector(rootSelector)))))) schedule();
        });
        document.addEventListener("play", guardHiddenPlayback, true);
        document.addEventListener("playing", guardHiddenPlayback, true);
        document.addEventListener("load", schedule, true);
        document.addEventListener("error", schedule, true);
        refresh();
    }

    function observe() {
        observer?.observe(document.body, { childList: true, subtree: true, attributes: true,
            attributeFilter: ["src", "srcset", "poster", "hidden", "class"] });
    }

    function setActive(value) {
        active = Boolean(value);
        if (!active) { clearTimeout(timer); timer = null; }
        else if (enabled || hideBodyMedia) refresh();
    }

    window.nnwMediaThumbnails = { configure, setActive };
    const initialStyle = document.getElementById("nnw-media-initial-visibility");
    if (initialStyle) {
        try {
            const initial = JSON.parse(initialStyle.dataset.configuration);
            // Replace the first-paint rule synchronously; no visible frame between the two states.
            initialStyle.remove();
            configure(initial.enabled, initial.nativeVideo, initial.labels, initial.hideBodyMedia);
        } catch (_) { /* Keep the initial rule if configuration is unavailable. */ }
    }
})();
