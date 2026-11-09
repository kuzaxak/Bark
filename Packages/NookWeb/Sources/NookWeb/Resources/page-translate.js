// Nook Translate
// Runs in the NookTranslate world, main frame only, installed on first use by PageSession+Translate.
// Text nodes get ids; Swift translates them and writes back. Originals stay here for Show Original.
(function (notify, bounded = true) {

    const SKIP = 'script, style, noscript, template, code, pre, kbd, samp, textarea, input, select, svg, math, '
        + '[contenteditable]:not([contenteditable="false"]), [translate="no"], .notranslate';
    const SAMPLE_LIMIT = 2048;
    const FLUSH_DELAY = 300;

    let originals = new Map(); // id -> { node, text }
    let originalCharacters = 0;
    const MAX_TRACKED = bounded ? 4096 : Infinity;
    const MAX_ORIGINAL_CHARACTERS = bounded ? 2 * 1024 * 1024 : Infinity;
    let tracked = new WeakSet();
    let nextID = 0;
    let observer = null;
    let pendingRoots = [];
    let flushTimer = null;
    let wholeDocumentPending = false;
    let needsPrune = false;
    const MAX_NODES = bounded ? 128 : Infinity;
    const MAX_TEXT = bounded ? 32768 : Infinity;

    function walk(root, visit) {
        if (root.ownerDocument !== document) { return; }
        if (root.nodeType === Node.TEXT_NODE) {
            if (!root.parentElement || root.parentElement.closest(SKIP)) { return; }
            visit(root);
            return;
        }
        if (root.nodeType !== Node.ELEMENT_NODE || root.closest(SKIP)) { return; }
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                if (node.nodeType === Node.ELEMENT_NODE) {
                    return node.matches(SKIP) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        let node;
        while ((node = walker.nextNode())) {
            if (visit(node) === false) { return; }
        }
    }

    function pruneDetached() {
        if (!bounded) { return; }
        for (const [id, entry] of originals) {
            if (!entry.node.isConnected || entry.node.ownerDocument !== document) {
                // Restore before forgetting: reinserting the same node must
                // not treat its translated text as the new original.
                if (entry.node.ownerDocument === document) { entry.node.nodeValue = entry.text; }
                originalCharacters -= entry.text.length;
                tracked.delete(entry.node);
                originals.delete(id);
            }
        }
        needsPrune = false;
    }

    function restore() {
        if (observer) { observer.disconnect(); observer = null; }
        pendingRoots = [];
        wholeDocumentPending = false;
        needsPrune = false;
        if (flushTimer !== null) { clearTimeout(flushTimer); flushTimer = null; }
        for (const entry of originals.values()) {
            if (entry.node.ownerDocument === document) { entry.node.nodeValue = entry.text; }
        }
        originals = new Map();
        originalCharacters = 0;
        tracked = new WeakSet();
    }

    // Untracked text nodes under root, as { id, text } with surrounding whitespace removed.
    function collect(root) {
        const out = [];
        let size = 0;
        walk(root, (node) => {
            if (node.ownerDocument !== document || tracked.has(node)) { return; }
            const text = node.nodeValue;
            const trimmed = text.trim();
            if (!trimmed || !/\p{L}/u.test(trimmed)) { return; }
            if (trimmed.length > MAX_TEXT) { throw new Error('Translation text exceeds the batch limit'); }
            if (originals.size >= MAX_TRACKED || originalCharacters + text.length > MAX_ORIGINAL_CHARACTERS) {
                throw new Error('Translation document exceeds the retention limit');
            }
            if (out.length >= MAX_NODES || size + trimmed.length > MAX_TEXT) {
                notify(out.splice(0)); size = 0;
            }
            size += trimmed.length;
            const id = String(nextID++);
            tracked.add(node);
            originals.set(id, { node: node, text: text, applied: false });
            originalCharacters += text.length;
            out.push({ id: id, text: trimmed });
        });
        return out;
    }

    // A stopped view task may already have consumed a batch without applying
    // its tail. The originals map is the document's authority for pending work.
    function replayPending() {
        let out = [], size = 0;
        for (const [id, entry] of originals) {
            if (entry.applied || !entry.node.isConnected || entry.node.ownerDocument !== document) { continue; }
            const text = entry.text.trim();
            if (out.length >= MAX_NODES || size + text.length > MAX_TEXT) {
                notify(out); out = []; size = 0;
            }
            out.push({ id: id, text: text }); size += text.length;
        }
        if (out.length) { notify(out); }
    }

    function flush() {
        flushTimer = null;
        const roots = pendingRoots;
        pendingRoots = [];
        wholeDocumentPending = false;
        try {
            if (needsPrune) { pruneDetached(); }
            for (const root of roots) {
                if (root.isConnected) {
                    const nodes = collect(root);
                    if (nodes.length) { notify(nodes); }
                }
            }
        } catch (_) {
            // Local cleanup precedes notification: the browser may have
            // unsubscribed or be shutting down before the abort is delivered.
            restore();
            notify(null);
        }
    }

    function observe() {
        if (observer) { return; }
        observer = new MutationObserver((records) => {
            for (const record of records) {
                if (bounded && record.removedNodes?.length) { needsPrune = true; }
                for (const node of record.addedNodes) {
                    if (wholeDocumentPending) { continue; }
                    if (pendingRoots.length < MAX_NODES) { pendingRoots.push(node); }
                    else { wholeDocumentPending = true; pendingRoots = [document.body || document.documentElement]; }
                }
            }
            if ((pendingRoots.length || needsPrune) && flushTimer === null) {
                flushTimer = setTimeout(flush, FLUSH_DELAY);
            }
        });
        observer.observe(document.body || document.documentElement, { childList: true, subtree: true });
    }

    return {
        // About 2 KB of the page's text and its declared language, for detection.
        sample() {
            let text = '';
            if (document.body) {
                walk(document.body, (node) => {
                    const trimmed = node.nodeValue.trim();
                    if (trimmed) { text += trimmed + ' '; }
                    return text.length < SAMPLE_LIMIT;
                });
            }
            return { text: text.slice(0, SAMPLE_LIMIT), lang: document.documentElement.lang || '' };
        },

        // Starts observing, replays native pending work and collects new text.
        start() {
            try {
                pruneDetached();
                observe();
                if (bounded) { replayPending(); }
                return document.body ? collect(document.body) : [];
            } catch (error) {
                restore();
                throw error;
            }
        },

        // pairs: [[id, translatedText]]. Keeps the original's leading and trailing whitespace.
        apply(pairs) {
            for (const [id, translated] of pairs) {
                const entry = originals.get(id);
                if (!entry || !entry.node.isConnected || entry.node.ownerDocument !== document) { continue; }
                const lead = entry.text.match(/^\s*/)[0];
                const trail = entry.text.match(/\s*$/)[0];
                entry.node.nodeValue = lead + translated + trail;
                entry.applied = true;
            }
        },

        restore
    };
})
