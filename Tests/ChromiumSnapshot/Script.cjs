// Licensed under GPL-3.0. See LICENSE.
// Runs the actual exported script with a deliberately small deterministic DOM.
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const scripts=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const {source}=scripts;
function element(tag,text='',attrs={},children=[]) {
 return {nodeType:1,tagName:tag.toUpperCase(),textContent:text,childNodes:children,
  hidden:false,id:'',value:attrs.value||'',disabled:false,
  getAttribute(k){return attrs[k]??null},hasAttribute(k){return k in attrs},
  matches(s){return s.split(',').map(x=>x.trim()).includes(tag)},closest(){return null}};
}
function fixture({allowComparison=false,installSource=true}={}) {
 let listeners=0,created=0,attached=0;
 const button=element('button','Save'),hidden=element('button','Secret',{'aria-hidden':'true'});
 button.id='save';
 button.outerHTML='<button id="save">Save</button>';
 button.getBoundingClientRect=()=>({left:10,top:20,width:120,height:32});
 const frame=element('iframe');Object.defineProperty(frame,'contentDocument',{get(){throw Error('cross-frame access')}});
 const input=element('input','',{'aria-label':'Draft',value:'unsaved'});
 const heading=element('h1','Title'),body=element('main','',{},[heading,button,input,hidden,frame]);
 const document = {
  body,
  documentElement: {appendChild() { attached++; }},
  querySelector(selector) {
   if (selector === '[') throw Error('invalid selector');
   if (selector === 'button' || selector === '#save') return button;
   if (selector === '#missing' || selector.startsWith('label[')) return null;
   return body;
  },
  querySelectorAll(selector) { return selector === '#save' ? [button] : []; },
  getElementById() { return null; },
  createElement(tag) {
   created++;
   if (!allowComparison) throw Error('picker UI created');
   if (tag !== 'div') return { tag };
   return {
    style: {},
    attachShadow({mode}) {
     assert.strictEqual(mode, 'closed');
     return {appendChild(ref) { assert.strictEqual(ref.tag, 'button'); }};
    },
    remove() { attached--; }
   };
  }
 };
 const context=vm.createContext({
  window:{}, document, location:{href:'https://fixture.test/page'}, CSS:{escape(value){return value;}},
  getComputedStyle(node){
   return {0:'width',length:1,display:'block',visibility:'visible',
    getPropertyValue(name){return name === 'width' ? (node === button ? '120px' : '80px') : ''; }};
  },
  addEventListener(){listeners++}, removeEventListener(){listeners--},
  setTimeout(){throw Error('timer installed')}
 });
 Object.defineProperty(context.window, "webkit", { get() { throw Error("accessed a WebKit message handler"); } });
 if (installSource) vm.runInContext(source,context);
 return {context,button,body,stats:()=>({listeners,created,attached})};
}
const f=fixture();
assert.deepStrictEqual(f.stats(),{listeners:0,created:0,attached:0});
let outline=vm.runInContext('window.__nookDevPicker.snapshot("",12,300)',f.context);
assert(outline.includes('- main')&&outline.includes('heading "Title" [level 1]'));
assert(outline.includes('textbox "Draft" [value "unsaved"]')&&!outline.includes('Secret'));
assert.strictEqual(vm.runInContext('window.__nookDevPicker.snapshot("button",12,300)',f.context),'- button "Save"');
assert.strictEqual(vm.runInContext('window.__nookDevPicker.snapshot("#missing",12,300)',f.context),null);
assert.throws(()=>vm.runInContext('window.__nookDevPicker.snapshot("[",12,300)',f.context),/invalid selector/);
f.button.textContent='Changed';
assert(vm.runInContext('window.__nookDevPicker.snapshot("",12,300)',f.context).includes('button "Changed"'));
const cut=vm.runInContext('window.__nookDevPicker.snapshot("",12,1)',f.context);
assert(cut.includes('cut at maxNodes or maxDepth'));
const deep=element('main','',{},[element('section','',{},[element('button','Deep')])]);f.body.childNodes=[deep];
assert(vm.runInContext('window.__nookDevPicker.snapshot("",1,300)',f.context).includes('cut at maxNodes or maxDepth'));
vm.runInContext(source,f.context);assert.deepStrictEqual(f.stats(),{listeners:0,created:0,attached:0});
const fresh=fixture();assert(vm.runInContext('window.__nookDevPicker.snapshot("button",12,300)',fresh.context).includes('"Save"'));
console.log('Actual DevPickerScript: dormant/no listeners or UI, selector/roles/state/hidden/frame isolation, mutation, caps and fresh document passed');


// The selected Chromium element is described in an isolated world. The
// temporary CSS baseline must be removed, including on subsequent reads.
const described = fixture({allowComparison:true});
const run = (body, context) => vm.runInContext(`(function () {${body}})()`, context);
const plain = value => JSON.parse(JSON.stringify(value));
assert.deepStrictEqual(plain(run(scripts.describe, described.context)), {
 url:'https://fixture.test/page', selector:'#save', tag:'button', role:'button', name:'Save',
 rect:{x:10,y:20,w:120,h:32}, html:'<button id="save">Save</button>', styles:[['width','120px']], source:''
});
assert.strictEqual(run(scripts.describeMissing, described.context), null);
assert.deepStrictEqual(described.stats(), {listeners:0,created:2,attached:0});

// A separate page context provides the framework hints without installing the
// isolated script there or changing the isolated element's native description.
const page = fixture({installSource:false});
page.button.__reactFiber$fixture = {
 type:{displayName:'SaveButton'}, _debugSource:{fileName:'Save.jsx',lineNumber:12}
};
assert.deepStrictEqual(plain(run(scripts.hints, page.context)), {react:['SaveButton'],source:'Save.jsx:12'});
assert.strictEqual(run(scripts.hintsMissing, page.context), null);
assert.strictEqual(page.context.window.__nookDevPicker, undefined);
assert.deepStrictEqual(page.stats(), {listeners:0,created:0,attached:0});
console.log('Actual DevPickerScript: isolated picked element, missing selector and page-world framework hints passed');
