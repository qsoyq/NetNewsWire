(() => {
    "use strict";
    let enabled = false;
    const articleBody = ".articleBody,.article-body";

    function expand(node) {
        if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_NODE) return;
        if (node.nodeType === Node.ELEMENT_NODE && node.matches("details") && node.closest(articleBody)) {
            node.open = true;
        }
        node.querySelectorAll("details").forEach(details => {
            if (details.closest(articleBody)) details.open = true;
        });
    }

    // Observe additions only: manually closing an existing disclosure stays possible.
    const observer = new MutationObserver(mutations => {
        if (!enabled) return;
        mutations.forEach(mutation => mutation.addedNodes.forEach(expand));
    });

    function configure(value) {
        const next = Boolean(value);
        if (enabled === next) return;
        enabled = next;
        observer.disconnect();
        if (enabled) {
            expand(document);
            observer.observe(document.documentElement, { childList: true, subtree: true });
        }
    }

    window.nnwArticleDisclosure = { configure };
})();
