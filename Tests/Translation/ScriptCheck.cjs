// Fixed translation script regression: no translator, network or browser required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
let currentDocument;
class Element {
  constructor(tag = 'p', children = []) {
    this.ownerDocument = currentDocument;
    this.nodeType = 1; this.tag = tag; this.children = children; this.isConnected = true;
    for (const child of children) child.parentElement = this;
  }
  matches() { return ['input', 'textarea', 'script', 'style', 'code'].includes(this.tag); }
  closest() { return this.matches() ? this : this.parentElement?.closest() ?? null; }
}
class TextNode {
  constructor(text) { this.ownerDocument = currentDocument; this.nodeType = 3; this.nodeValue = text; this.isConnected = true; }
}
const first = new TextNode('  Bonjour  '), excluded = new TextNode('secret');
const body = new Element('body', [new Element('p', [first]), new Element('input', [excluded])]);
let observer;
const timers = new Map(); let nextTimer = 0;
const context = vm.createContext({
  Node: {TEXT_NODE: 3, ELEMENT_NODE: 1},
  NodeFilter: {SHOW_ELEMENT: 1, SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3},
  document: {body, documentElement: {lang: 'fr'}, createTreeWalker(root, _, filter) {
    const accepted = [];
    function walk(node) {
      const result = filter.acceptNode(node);
      if (result === 2) return;
      if (result === 1) accepted.push(node);
      for (const child of node.children ?? []) walk(child);
    }
    for (const child of root.children ?? []) walk(child);
    let index = 0; return {nextNode: () => accepted[index++] ?? null};
  }},
  MutationObserver: class {
    constructor(callback) { this.callback = callback; observer = this; }
    observe() { this.active = true; }
    disconnect() { this.active = false; }
  },
  setTimeout(fn) { timers.set(++nextTimer, fn); return nextTimer; },
  clearTimeout(id) { timers.delete(id); }
});
currentDocument = context.document;
function assignDocument(node) {
  node.ownerDocument = currentDocument;
  for (const child of node.children ?? []) assignDocument(child);
}
assignDocument(body);
const script = fs.readFileSync('Packages/NookWeb/Sources/NookWeb/Resources/page-translate.js', 'utf8');
const factory = vm.runInContext(script, context);
const batches = [];
const api = factory(nodes => batches.push(JSON.parse(JSON.stringify(nodes))));
assert.equal(api.sample().lang, 'fr');
assert.equal(api.sample().text.trim(), 'Bonjour');
const initial = api.start(); assert.equal(initial.length, 1);
api.apply([[initial[0].id, 'Hello']]);
assert.equal(first.nodeValue, '  Hello  '); assert.equal(excluded.nodeValue, 'secret');
const sameObserver = observer;
assert.equal(api.start().length, 0);
assert.equal(observer, sameObserver); assert.equal(first.nodeValue, '  Hello  ');
// Removed nodes are restored and forgotten on the existing mutation flush.
first.isConnected = false; body.children[0].children = [];
observer.callback([{addedNodes: [], removedNodes: [first]}]);
for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
assert.equal(first.nodeValue, '  Bonjour  ');
first.isConnected = true; body.children[0].children = [first];
observer.callback([{addedNodes: [first], removedNodes: []}]);
for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
const reinserted = batches.at(-1)[0];
assert.equal(reinserted.text, 'Bonjour'); assert.notEqual(reinserted.id, initial[0].id);
api.apply([[reinserted.id, 'Hello']]);
const added = new TextNode('Salut'); added.parentElement = body;
observer.callback([{addedNodes: [added]}]);
assert.equal(timers.size, 1);
for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
assert.equal(batches.at(-1)[0].text, 'Salut');
api.apply([[batches.at(-1)[0].id, 'Hi']]); assert.equal(added.nodeValue, 'Hi');
observer.callback([{addedNodes: [new TextNode('pending')]}]);
api.restore(); assert.equal(timers.size, 0); assert.equal(observer.active, false);
assert.equal(first.nodeValue, '  Bonjour  '); assert.equal(added.nodeValue, 'Salut');
assert.equal(context.__nookTranslate, undefined); assert.equal(context.webkit, undefined);
// A large initial document streams bounded batches, rather than losing its tail.
body.children = Array.from({length: 400}, (_, i) => new TextNode(`word${i}`));
for (const node of body.children) node.parentElement = body;
const beforeLarge = batches.length;
const tail = api.start();
assert.ok(tail.length <= 128); assert.ok(batches.every(batch => batch.length <= 128));
assert.equal(batches.slice(beforeLarge).reduce((n, batch) => n + batch.length, tail.length), 400);
api.restore();
body.children = [new TextNode('a'.repeat(32769))]; body.children[0].parentElement = body;
assert.throws(() => api.start(), /batch limit/);
assert.equal(observer.active, false); assert.equal(timers.size, 0);
const legacy = factory(() => {}, false); assert.equal(legacy.start().length, 1); legacy.restore();
// Both native retention bounds clean up locally, even without a host reply.
body.children = Array.from({length: 4097}, (_, i) => new TextNode(`node${i}`));
for (const node of body.children) node.parentElement = body;
assert.throws(() => api.start(), /retention limit/);
assert.equal(observer.active, false); assert.equal(timers.size, 0);
body.children = Array.from({length: 129}, () => new TextNode('a'.repeat(16384)));
for (const node of body.children) node.parentElement = body;
assert.throws(() => api.start(), /retention limit/);
assert.equal(observer.active, false); assert.equal(timers.size, 0);
const survivor = new TextNode('Original'); survivor.parentElement = body; body.children = [survivor];
const fresh = api.start(); assert.equal(fresh.length, 1);
api.apply([[fresh[0].id, 'Translated']]);
const oversized = new TextNode('x'.repeat(32769)); oversized.parentElement = body;
observer.callback([{addedNodes: [oversized], removedNodes: []}]);
for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
assert.equal(batches.at(-1), null); assert.equal(survivor.nodeValue, 'Original');
assert.equal(observer.active, false); assert.equal(timers.size, 0);
// A new start can collect the same node after abort without stale tracking.
body.children = [survivor]; assert.equal(api.start().length, 1); api.restore();
// Connected nodes adopted elsewhere are neither translated nor restored by the old document.
const adopted = new TextNode('Own document'); adopted.parentElement = body; body.children = [adopted];
const owned = api.start(); api.apply([[owned[0].id, 'Translated here']]);
adopted.ownerDocument = {foreign: true};
api.apply([[owned[0].id, 'Forbidden foreign write']]);
assert.equal(adopted.nodeValue, 'Translated here');
observer.callback([{addedNodes: [], removedNodes: [adopted]}]);
for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
assert.equal(adopted.nodeValue, 'Translated here'); api.restore();
assert.equal(adopted.nodeValue, 'Translated here');
// A cancelled consumer must recover only unapplied work from the same map.
api.restore();
body.children = Array.from({length:1000},(_,i)=>new TextNode(`Source${i}`));
for (const node of body.children) node.parentElement=body;
const initialOffset = batches.length;
const firstTail = api.start();
const firstWork = batches.slice(initialOffset).flat().concat(firstTail);
assert.equal(firstWork.length,1000);
const appliedIDs = new Set(firstWork.slice(0,40).map(node=>node.id));
api.apply(firstWork.slice(0,40).map((node,i)=>[node.id,`Translated${i}`]));
function resumeWork() {
  const offset=batches.length;
  const tail=api.start();
  return batches.slice(offset).flat().concat(tail);
}
const resumed = resumeWork();
assert.equal(resumed.length,960);
assert.ok(resumed.every(node=>!appliedIDs.has(node.id)));
assert.deepEqual(resumeWork().map(node=>node.id),resumed.map(node=>node.id));
const hidden = new TextNode('Added while hidden'); hidden.parentElement=body; body.children.push(hidden);
observer.callback([{addedNodes:[hidden],removedNodes:[]}]);
for (const [id,fn] of [...timers]) { timers.delete(id);fn(); }
const withHidden=resumeWork();
assert.equal(withHidden.length,961);
assert.ok(withHidden.some(node=>node.text==='Added while hidden'));
assert.ok(withHidden.every(node=>!appliedIDs.has(node.id)));
api.apply(withHidden.map(node=>[node.id,'Done']));
assert.equal(resumeWork().length,0);
api.restore();
assert.equal(body.children[0].nodeValue,'Source0'); assert.equal(hidden.nodeValue,'Added while hidden');
const restart=resumeWork(); assert.equal(restart.length,1001);
assert.ok(restart.every(node=>!appliedIDs.has(node.id))); api.restore();
console.log('Translation script: sample/apply/restore, mutations, exclusions and bounded streaming PASS');
