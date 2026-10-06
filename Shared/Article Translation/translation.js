(() => {
    "use strict";
    const ignored = "script,style,noscript,pre,textarea,input,button,select,svg,math,video,audio,.articleTitle,.article-title,[hidden],[aria-hidden='true'],[translate='no'],.notranslate,[data-nnw-translation]";
    let documentID = "", options = {}, units = new Map(), identities = new WeakMap(), nextID = 0;
    let state = "idle";
    const rendered = new Map();
    const replacements = new Map();

    function originalText(node) {
        const replacement = replacements.get(node);
        return replacement && node.data === replacement.translated ? replacement.original : node.data;
    }

    function excluded(element) {
        if (!element || element.closest(ignored)) return true;
        const style = getComputedStyle(element);
        return style.display === "none" || style.visibility === "hidden";
    }

    function textOf(nodes) {
        function text(node) {
            if (node.nodeType === Node.TEXT_NODE) return originalText(node);
            if (node.nodeType !== Node.ELEMENT_NODE || excluded(node)) return "";
            if (node.tagName === "BR") return "\n";
            if (node.tagName === "CODE") return "`" + node.textContent + "`";
            return Array.from(node.childNodes).map(text).join("");
        }
        return nodes.map(text).join("").replace(/[\t ]+/g, " ").trim();
    }

    function collect() {
        units = new Map();
        const roots = Array.from(document.querySelectorAll(".articleBody,.article-body"));
        const uniqueRoots = roots.filter(root => !roots.some(other => other !== root && other.contains(root)));
        if (options.displayMode === "replaceOriginal") {
            function visit(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                    const text = originalText(node).trim();
                    if (!text || excluded(node.parentElement)) return;
                    let id = identities.get(node);
                    if (id === undefined) {
                        id = String(nextID++);
                        identities.set(node, id);
                    }
                    const paragraph = node.parentElement.closest("p,li,div,blockquote,td,th,h1,h2,h3,h4,h5,h6,dt,dd,figcaption");
                    const context = paragraph ? Array.from(textOf([paragraph])).slice(0, 600).join("") : undefined;
                    units.set(id, { id, text, context, anchor: node, nodes: [node] });
                } else if (node.nodeType === Node.ELEMENT_NODE && !excluded(node) && node.tagName !== "CODE") {
                    Array.from(node.childNodes).forEach(visit);
                }
            }
            uniqueRoots.forEach(visit);
            return JSON.stringify(Array.from(units.values(), unit => ({ id: unit.id, text: unit.text, context: unit.context })));
        }
        function scan(element) {
            if (excluded(element)) return;
            let group = [];
            function flush() {
                const text = textOf(group);
                if (text && group.length) {
                    const anchor = group[group.length - 1];
                    let id = identities.get(anchor);
                    if (id === undefined) {
                        id = String(nextID++);
                        identities.set(anchor, id);
                    }
                    units.set(id, { id, text, anchor, nodes: group.slice() });
                }
                group = [];
            }
            Array.from(element.childNodes).forEach(node => {
                if (node.nodeType === Node.TEXT_NODE) {
                    group.push(node);
                } else if (node.nodeType === Node.ELEMENT_NODE) {
                    if (excluded(node)) { flush(); return; }
                    const display = getComputedStyle(node).display;
                    if (node.tagName !== "BR" && !display.startsWith("inline") && display !== "contents") {
                        flush();
                        scan(node);
                    } else {
                        group.push(node);
                    }
                }
            });
            flush();
        }
        uniqueRoots.forEach(scan);
        return JSON.stringify(Array.from(units.values(), unit => ({ id: unit.id, text: unit.text })));
    }

    function restore(expectedID) {
        if (expectedID !== documentID) return;
        rendered.forEach(element => element.remove());
        rendered.clear();
        replacements.forEach((replacement, node) => {
            if (node.data === replacement.translated) node.data = replacement.original;
        });
        replacements.clear();
        setState(expectedID, "idle", "");
    }

    function apply(expectedID, translations) {
        if (expectedID !== documentID) return;
        translations.forEach(item => {
            const unit = units.get(item.id);
            if (!unit || !unit.anchor.isConnected) return;
            const currentText = options.displayMode === "replaceOriginal" ? originalText(unit.anchor).trim() : textOf(unit.nodes);
            if (currentText !== unit.text) return;
            if (options.displayMode === "replaceOriginal") {
                const node = unit.anchor;
                const original = originalText(node);
                const leading = original.match(/^\s*/)[0];
                const trailing = original.match(/\s*$/)[0];
                node.data = leading + item.text.trim() + trailing;
                replacements.set(node, { original, translated: node.data });
                return;
            }
            let element = rendered.get(item.id);
            if (!element || !element.isConnected) {
                element = document.createElement("div");
                element.dataset.nnwTranslation = "text";
                element.className = "nnw-translation-text";
                unit.anchor.parentNode.insertBefore(element, unit.anchor.nextSibling);
                rendered.set(item.id, element);
            }
            element.lang = options.languageTag || "";
            element.textContent = item.text;
        });
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
                .nnw-translation-text { margin: .5em 0 1em; font-weight: normal; white-space: pre-wrap; overflow-wrap: anywhere; opacity: .85; }
            `;
            document.head.appendChild(style);
        }
        setState(documentID, "idle", "");
    }

    window.nnwTranslation = { configure, collect, apply, restore, setState };
})();
