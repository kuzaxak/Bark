// Licensed under GPL-3.0. See LICENSE.
//
//  DevPickerScript.swift
//  Nook
//
//  DOM descriptions and accessibility snapshots for Chromium developer tools.

import Foundation

enum DevPickerScript {
    /// Reads what only the page world sees on the picked element.
    static let hintsSource = """
    const el = document.querySelector(selector);
    if (!el) return null;
    const out = {};
    const fk = Object.keys(el).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
    if (fk) {
      const names = [];
      for (let f = el[fk]; f && names.length < 8; f = f.return) {
        const t = f.type;
        if (t && typeof t !== 'string') {
          const n = t.displayName || t.name || (t.render && (t.render.displayName || t.render.name));
          if (n && !names.includes(n)) names.push(n);
        }
        if (!out.source && f._debugSource) out.source = f._debugSource.fileName + ':' + f._debugSource.lineNumber;
      }
      if (names.length) out.react = names;
    }
    if (el.__vueParentComponent) {
      const names = [];
      for (let v = el.__vueParentComponent; v && names.length < 8; v = v.parent) {
        const t = v.type || {};
        const n = t.name || t.__name || (t.__file && t.__file.split('/').pop());
        if (n) names.push(n);
        if (!out.source && t.__file) out.source = t.__file;
      }
      if (names.length) out.vue = names;
    }
    if (!out.source && el.__svelte_meta && el.__svelte_meta.loc) {
      out.source = el.__svelte_meta.loc.file + ':' + (el.__svelte_meta.loc.line + 1);
    }
    return out;
    """

    /// The element at `selector` as the picker sends it, for a world the picker never started in.
    static func describeScript(selector: String) -> String? {
        literal(selector).map { source + "\nreturn window.__nookDevPicker.describe(\($0));" }
    }

    /// `hintsSource` for one selector, as a script body for the page world.
    static func hintsScript(selector: String) -> String? {
        literal(selector).map { "const selector = \($0);\n" + hintsSource }
    }

    private static func literal(_ string: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static let source = """
    (function () {
      if (window.__nookDevPicker) return;
      const STYLE_ORDER = ['display', 'position', 'top', 'right', 'bottom', 'left', 'z-index', 'width', 'height',
        'min-width', 'max-width', 'min-height', 'max-height', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
        'padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'flex-direction', 'flex-wrap', 'flex-grow',
        'flex-shrink', 'flex-basis', 'justify-content', 'align-items', 'align-self', 'gap', 'grid-template-columns',
        'grid-template-rows', 'overflow-x', 'overflow-y', 'box-sizing', 'color', 'background-color', 'background-image',
        'font-family', 'font-size', 'font-weight', 'line-height', 'text-align', 'opacity', 'visibility', 'transform',
        'border-top-width', 'border-top-style', 'border-top-color', 'border-top-left-radius', 'box-shadow', 'cursor'];

      function unique(sel) { try { return document.querySelectorAll(sel).length === 1; } catch (_) { return false; } }

      function selectorFor(el) {
        if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
        const parts = [];
        for (let node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
          const test = node.getAttribute('data-testid');
          if (test && unique('[data-testid="' + CSS.escape(test) + '"]')) {
            parts.unshift('[data-testid="' + CSS.escape(test) + '"]');
            break;
          }
          if (node !== el && node.id && unique('#' + CSS.escape(node.id))) { parts.unshift('#' + CSS.escape(node.id)); break; }
          let part = node.tagName.toLowerCase();
          // Readable class names first; hashed ones (css-1x2y3z, sc-abc123) change on every build.
          const classes = typeof node.className === 'string'
            ? node.className.trim().split(/\\s+/).filter(c => c && !/\\d{2}|^(css|sc|jsx)-/.test(c)).slice(0, 2) : [];
          if (classes.length) part += '.' + classes.map(c => CSS.escape(c)).join('.');
          const same = node.parentElement ? Array.from(node.parentElement.children).filter(c => c.matches(part)) : [];
          if (same.length > 1) part += ':nth-of-type(' + (Array.from(node.parentElement.children)
            .filter(c => c.tagName === node.tagName).indexOf(node) + 1) + ')';
          parts.unshift(part);
          if (unique(parts.join(' > '))) break;
        }
        return parts.join(' > ');
      }

      const IMPLICIT = { button: 'button', nav: 'navigation', main: 'main', header: 'banner', footer: 'contentinfo',
        aside: 'complementary', section: 'region', article: 'article', ul: 'list', ol: 'list', li: 'listitem', select: 'combobox', textarea: 'textbox',
        form: 'form', table: 'table', dialog: 'dialog', img: 'img', h1: 'heading', h2: 'heading', h3: 'heading',
        h4: 'heading', h5: 'heading', h6: 'heading', option: 'option', progress: 'progressbar' };
      function roleOf(el) {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.split(/\\s+/)[0];
        const tag = el.tagName.toLowerCase();
        if (tag === 'a') return el.hasAttribute('href') ? 'link' : '';
        if (tag === 'input') {
          const t = (el.getAttribute('type') || 'text').toLowerCase();
          return { checkbox: 'checkbox', radio: 'radio', range: 'slider', button: 'button', submit: 'button',
                   reset: 'button', search: 'searchbox' }[t] || 'textbox';
        }
        return IMPLICIT[tag] || '';
      }
      function nameOf(el) {
        const by = el.getAttribute('aria-labelledby');
        const labelled = by && by.split(/\\s+/).map(id => document.getElementById(id)).filter(Boolean)
          .map(n => n.textContent).join(' ');
        const forLabel = (el.id && document.querySelector('label[for="' + CSS.escape(el.id) + '"]')) ||
          (el.matches('input, select, textarea') && el.closest('label'));
        const name = el.getAttribute('aria-label') || labelled || el.getAttribute('alt') || el.getAttribute('title') ||
          (forLabel && forLabel.textContent) || el.getAttribute('placeholder') || el.textContent || '';
        return name.replace(/\\s+/g, ' ').trim().slice(0, 200);
      }

      function stylesOf(el) {
        const tag = el.tagName.toLowerCase();
        const holder = document.createElement('div');
        // Off screen rather than hidden: visibility and pointer-events would be inherited and show as diffs.
        holder.style.cssText = 'all: initial; position: fixed; left: -10000px; top: 0';
        const root = holder.attachShadow({ mode: 'closed' });
        // A custom element's constructor would run on createElement, so compare those against a div.
        const ref = document.createElement(tag.includes('-') ? 'div' : tag);
        root.appendChild(ref);
        document.documentElement.appendChild(holder);
        const mine = getComputedStyle(el), base = getComputedStyle(ref);
        const color = mine.getPropertyValue('color');
        const diffs = [];
        for (let i = 0; i < mine.length; i++) {
          const p = mine[i];
          if (p.startsWith('-webkit-') || p.startsWith('--') || p.includes('inline') || p.includes('block-') ||
              p.includes('-start-') || p.includes('-end-') || p.endsWith('-origin')) continue;
          const v = mine.getPropertyValue(p);
          if (v === base.getPropertyValue(p)) continue;
          // Colors that only follow currentColor say nothing color does not.
          if (p.endsWith('-color') && p !== 'background-color' && p !== 'border-top-color' && v === color) continue;
          // One border side stands for all four when they match.
          const side = p.match(/^border-(right|bottom|left)-(width|style|color)$/);
          if (side && v === mine.getPropertyValue('border-top-' + side[2])) continue;
          const corner = p.match(/^border-(top-right|bottom-right|bottom-left)-radius$/);
          if (corner && v === mine.getPropertyValue('border-top-left-radius')) continue;
          diffs.push([p, v]);
        }
        holder.remove();
        const rank = p => { const i = STYLE_ORDER.indexOf(p); return i < 0 ? STYLE_ORDER.length : i; };
        diffs.sort((a, b) => rank(a[0]) - rank(b[0]));
        return diffs.slice(0, 40);
      }

      function sourceOf(el) {
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
          const path = n.getAttribute('data-inspector-relative-path');
          if (path) return path + (n.getAttribute('data-inspector-line') ? ':' + n.getAttribute('data-inspector-line') : '');
          const src = n.getAttribute('data-source') || n.getAttribute('data-source-loc');
          if (src) return src;
        }
        return '';
      }

      function bundle(el) {
        const r = el.getBoundingClientRect();
        let html = el.outerHTML;
        if (html.length > 2048) html = html.slice(0, 2048) + '\\n<!-- cut at 2 KB -->';
        return { url: location.href, selector: selectorFor(el), tag: el.tagName.toLowerCase(), role: roleOf(el),
                 name: nameOf(el), rect: { x: r.left, y: r.top, w: r.width, h: r.height }, html,
                 styles: stylesOf(el), source: sourceOf(el) };
      }

      // Accessibility outline for agents: one line per role, generic wrappers flattened, hidden content skipped.
      const LEAF = new Set(['link', 'button', 'heading', 'img', 'textbox', 'searchbox', 'checkbox', 'radio',
        'slider', 'combobox', 'option', 'progressbar', 'switch', 'tab', 'menuitem']);
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK']);
      function snapshot(selector, maxDepth, maxNodes) {
        const root = selector ? document.querySelector(selector) : document.body;
        if (!root) return null;
        const lines = [];
        let omitted = 0;
        function emit(depth, text) {
          if (lines.length >= maxNodes) { omitted++; return false; }
          lines.push('  '.repeat(depth) + '- ' + text);
          return true;
        }
        function hidden(el) {
          if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
          const cs = getComputedStyle(el);
          return cs.display === 'none' || cs.visibility === 'hidden';
        }
        function states(el, role) {
          const s = [];
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') s.push('disabled');
          if (role === 'checkbox' || role === 'radio' || role === 'switch') s.push(el.checked || el.getAttribute('aria-checked') === 'true' ? 'checked' : 'unchecked');
          const exp = el.getAttribute('aria-expanded'); if (exp) s.push(exp === 'true' ? 'expanded' : 'collapsed');
          if (el.getAttribute('aria-selected') === 'true') s.push('selected');
          if (role === 'heading') s.push('level ' + (el.getAttribute('aria-level') || el.tagName.slice(1)));
          if ((role === 'textbox' || role === 'searchbox' || role === 'combobox') && el.value) s.push('value "' + String(el.value).slice(0, 60) + '"');
          if (role === 'link' && el.getAttribute('href')) s.push('href ' + el.getAttribute('href').slice(0, 80));
          return s.length ? ' [' + s.join(', ') + ']' : '';
        }
        function walk(node, depth) {
          if (depth > maxDepth) { omitted++; return; }
          if (node.nodeType === 3) {
            const t = node.textContent.replace(/\\s+/g, ' ').trim();
            if (t) emit(depth, 'text "' + t.slice(0, 100) + '"');
            return;
          }
          if (node.nodeType !== 1 || SKIP.has(node.tagName) || hidden(node)) return;
          const role = roleOf(node);
          if (!role) { for (const c of node.childNodes) walk(c, depth); return; }
          const name = LEAF.has(role) || node.hasAttribute('aria-label') ? nameOf(node).slice(0, 80) : '';
          if (!emit(depth, role + (name ? ' "' + name + '"' : '') + states(node, role))) return;
          if (!LEAF.has(role)) for (const c of node.childNodes) walk(c, depth + 1);
        }
        walk(root, 0);
        // Children of a cut node are never visited, so a count here would undercount.
        if (omitted) lines.push('- … cut at maxNodes or maxDepth; raise them or pick a narrower selector');
        return lines.join('\\n');
      }
      function describe(selector) { const el = document.querySelector(selector); return el ? bundle(el) : null; }

      window.__nookDevPicker = { snapshot, describe };
    })();
    """
}
