// Licensed under GPL-3.0. See LICENSE.
// Runs the actual exported script with a deliberately small deterministic DOM.
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(process.argv[2],'utf8');
function element(tag,text='',attrs={},children=[]) {
 return {nodeType:1,tagName:tag.toUpperCase(),textContent:text,childNodes:children,
  hidden:false,id:'',value:attrs.value||'',disabled:false,
  getAttribute(k){return attrs[k]??null},hasAttribute(k){return k in attrs},
  matches(s){return s.split(',').map(x=>x.trim()).includes(tag)},closest(){return null}};
}
function fixture() {
 let listeners=0,created=0;
 const button=element('button','Save'),hidden=element('button','Secret',{'aria-hidden':'true'});
 const frame=element('iframe');Object.defineProperty(frame,'contentDocument',{get(){throw Error('cross-frame access')}});
 const input=element('input','',{'aria-label':'Draft',value:'unsaved'});
 const heading=element('h1','Title'),body=element('main','',{},[heading,button,input,hidden,frame]);
 const document={body,querySelector(selector){if(selector==='#missing')return null;if(selector==='[')throw Error('invalid selector');return selector==='button'?button:body},
  getElementById(){return null},createElement(){created++;throw Error('picker UI created')}};
 const context=vm.createContext({window:{},document,getComputedStyle(){return {display:'block',visibility:'visible'}},
  addEventListener(){listeners++},removeEventListener(){listeners--},setTimeout(){throw Error('timer installed')}});
 vm.runInContext(source,context);
 return {context,button,body,stats:()=>({listeners,created})};
}
const f=fixture();
assert.deepStrictEqual(f.stats(),{listeners:0,created:0});
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
vm.runInContext(source,f.context);assert.deepStrictEqual(f.stats(),{listeners:0,created:0});
const fresh=fixture();assert(vm.runInContext('window.__nookDevPicker.snapshot("button",12,300)',fresh.context).includes('"Save"'));
console.log('Actual DevPickerScript: dormant/no listeners or UI, selector/roles/state/hidden/frame isolation, mutation, caps and fresh document passed');
