(() => {
    "use strict";
    const ignored = "script,style,noscript,pre,code,textarea,input,button,select,svg,math,video,audio,.articleTitle,.article-title,[hidden],[aria-hidden='true'],[translate='no'],.notranslate,[data-nnw-translation]";
    const boundaries = new Set("summary,p,div,li,blockquote,td,th,h1,h2,h3,h4,h5,h6,dt,dd,figcaption,details,section,article,header,footer,ul,ol,dl,table,thead,tbody,tfoot,tr,figure,address,hr,fieldset".toUpperCase().split(","));
    let documentID = "", options = {}, units = new Map(), identities = new WeakMap(), nextID = 0;
    let state = "idle";
    const rendered = new Map();
    const replacements = new Map();
    const translated = new Map();

    function originalText(node) {
        const replacement = replacements.get(node);
        return replacement && node.data === replacement.translated ? replacement.original : node.data;
    }

    function excluded(element) {
        if (!element || element.closest(ignored)) return true;
        const style = getComputedStyle(element);
        return style.display === "none" || style.visibility === "hidden";
    }

    function isBoundary(element) {
        if (boundaries.has(element.tagName)) return true;
        const display = getComputedStyle(element).display;
        return display !== "contents" && !display.startsWith("inline");
    }

    function isURLText(text) {
        if (!text || /\s/.test(text)) return false;
        try {
            const url = new URL(text);
            return ["http:", "https:", "ftp:"].includes(url.protocol) && !!url.hostname;
        } catch {
            return false;
        }
    }

    function preserveURL(node, text) {
        if (isURLText(text)) return true;
        const link = node.parentElement?.closest("a");
        if (!link) return false;
        const walker = document.createTreeWalker(link, NodeFilter.SHOW_TEXT);
        let label = "";
        while (walker.nextNode()) {
            if (!walker.currentNode.parentElement.closest("[data-nnw-translation]")) label += originalText(walker.currentNode);
        }
        return isURLText(label.trim());
    }

    function collect() {
        units = new Map();
        const boundaryCache = new WeakMap();
        function boundary(element) {
            if (boundaryCache.has(element)) return boundaryCache.get(element);
            // An inline wrapper containing blocks gets its own runs so output can stay beside its source.
            const result = isBoundary(element) || Array.from(element.children).some(child => !excluded(child) && boundary(child));
            boundaryCache.set(element, result);
            return result;
        }
        const roots = Array.from(document.querySelectorAll(".articleBody,.article-body"));
        const uniqueRoots = roots.filter(root => !roots.some(other => other !== root && other.contains(root)));
        uniqueRoots.forEach((root, rootIndex) => {
            function scan(container, containerPath) {
                if (excluded(container)) return;
                let parts = [], anchor;
                function flush() {
                    const context = Array.from(parts.map(part => part.original).join("").replace(/[\t ]+/g, " ").trim()).slice(0, 600).join("");
                    const group = { root, container, anchor, parts, units: [] };
                    parts.forEach(part => {
                        if (!part.text || part.preserve) return;
                        let identity = identities.get(part.node);
                        if (!identity || identity.original !== part.original || identity.context !== context || identity.parent !== part.parent || identity.root !== root) {
                            identity = { id: String(nextID++), original: part.original, context, parent: part.parent, root };
                            identities.set(part.node, identity);
                        }
                        const unit = { ...part, id: identity.id, context, group };
                        group.units.push(unit);
                        units.set(unit.id, unit);
                    });
                    group.id = group.units[0]?.id;
                    parts = [];
                    anchor = undefined;
                }
                function visit(node, path, insertionAnchor) {
                    if (node.nodeType === Node.TEXT_NODE) {
                        const original = originalText(node);
                        const text = original.trim();
                        parts.push({ node, parent: node.parentNode, path: { root: rootIndex, children: path }, original,
                            text, preserve: preserveURL(node, text), leading: original.match(/^\s*/)[0], trailing: original.match(/\s*$/)[0] });
                        anchor = insertionAnchor;
                    } else if (node.nodeType === Node.ELEMENT_NODE) {
                        // Our own inserted output must not change subsequent snapshots or groups.
                        if (node.hasAttribute("data-nnw-translation")) return;
                        if (excluded(node)) {
                            if (node === insertionAnchor) flush();
                            return;
                        }
                        if (node.tagName === "BR") {
                            parts.push({ node, parent: node.parentNode, original: "\n" });
                            anchor = insertionAnchor;
                        } else if (boundary(node)) {
                            flush();
                            scan(node, path);
                        } else {
                            Array.from(node.childNodes).forEach((child, index) => visit(child, [...path, index], insertionAnchor));
                        }
                    }
                }
                Array.from(container.childNodes).forEach((child, index) => visit(child, [...containerPath, index], child));
                flush();
            }
            scan(root, []);
        });
        translated.forEach((_, id) => { if (!units.has(id)) translated.delete(id); });
        rendered.forEach((element, id) => {
            if (!units.has(id)) {
                element.remove();
                rendered.delete(id);
            }
        });
        new Set(Array.from(units.values(), unit => unit.group)).forEach(renderGroup);
        return JSON.stringify(Array.from(units.values(), unit => ({ id: unit.id, text: unit.text, context: unit.context })));
    }

    function validPart(part, group) {
        return group.root.isConnected && group.root.contains(part.node) && group.container.contains(part.node) &&
            part.node.parentNode === part.parent && (part.node.nodeType === Node.TEXT_NODE ? originalText(part.node) === part.original : part.node.tagName === "BR");
    }

    function renderGroup(group) {
        // A group is displayed only when all its text nodes have a result, even when batches finish out of order.
        if (!group.anchor?.isConnected || group.anchor.parentNode !== group.container || !group.parts.every(part => validPart(part, group)) ||
            !group.units.every(unit => translated.get(unit.id)?.original === unit.original)) {
            rendered.get(group.id)?.remove();
            rendered.delete(group.id);
            return;
        }
        let element = rendered.get(group.id);
        if (!element?.isConnected) {
            element = document.createElement("span");
            element.dataset.nnwTranslation = "text";
            element.className = "nnw-translation-text";
            group.container.insertBefore(element, group.anchor.nextSibling);
            rendered.set(group.id, element);
        }
        const byNode = new Map(group.units.map(unit => [unit.node, unit]));
        element.lang = options.languageTag || "";
        element.textContent = group.parts.map(part => {
            const unit = byNode.get(part.node);
            return unit ? unit.leading + translated.get(unit.id).text + unit.trailing : part.original;
        }).join("").trim();
    }

    function restore(expectedID) {
        if (expectedID !== documentID) return;
        rendered.forEach(element => element.remove());
        rendered.clear();
        translated.clear();
        replacements.forEach((replacement, node) => {
            if (node.data === replacement.translated) node.data = replacement.original;
        });
        replacements.clear();
        setState(expectedID, "idle", "");
    }

    function apply(expectedID, translations) {
        if (expectedID !== documentID) return;
        const changedGroups = new Set();
        translations.forEach(item => {
            const unit = units.get(item.id);
            if (!unit || typeof item.text !== "string" || !item.text.trim() || !validPart(unit, unit.group) || preserveURL(unit.node, unit.text)) return;
            if (options.displayMode === "replaceOriginal") {
                unit.node.data = unit.leading + item.text.trim() + unit.trailing;
                replacements.set(unit.node, { original: unit.original, translated: unit.node.data });
                return;
            }
            translated.set(unit.id, { original: unit.original, text: item.text.trim() });
            changedGroups.add(unit.group);
        });
        changedGroups.forEach(renderGroup);
    }

    function setState(expectedID, value, detail) {
        if (expectedID !== documentID) return;
        state = value;
    }

    function configure(configuration) {
        if (documentID) restore(documentID);
        documentID = configuration.documentID;
        options = configuration;
        identities = new WeakMap();
        nextID = 0;
        units.clear();
        if (!configuration.enabled) return;
        if (!document.getElementById("nnw-translation-style")) {
            const style = document.createElement("style");
            style.id = "nnw-translation-style";
            style.textContent = `
                .nnw-translation-text { display: block; margin: .5em 0 1em; font-weight: normal; white-space: pre-wrap; overflow-wrap: anywhere; opacity: .85; }
            `;
            document.head.appendChild(style);
        }
        setState(documentID, "idle", "");
    }

    window.nnwTranslation = { configure, collect, apply, restore, setState };
})();
