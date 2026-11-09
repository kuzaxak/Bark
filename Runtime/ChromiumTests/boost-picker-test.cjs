// Fixed picker lifecycle regression. No browser/network or external packages.
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const source=fs.readFileSync(process.argv[2],'utf8');
function fixture(){
  const handlers=new Map(), windows=new Map(), replies=[];
  const root={style:{cursor:'help'},appendChild(node){node.parent=this;},nodeType:1};
  const target={id:'chosen',nodeType:1,parentElement:root,localName:'button',getBoundingClientRect(){return {left:1,top:2,width:3,height:4};}};
  root.children=[target];
  const document={documentElement:root,body:{},visibilityState:'visible',
    createElement(){return {style:{},remove(){this.removed=true;}};},
    querySelectorAll(selector){return selector==='#chosen'?[target]:[];},
    addEventListener(type,fn){handlers.set(type,fn);},removeEventListener(type,fn){if(handlers.get(type)===fn)handlers.delete(type);}};
  const window={addEventListener(type,fn){windows.set(type,fn);},removeEventListener(type,fn){if(windows.get(type)===fn)windows.delete(type);}};
  let controller,allowed=true;
  const factory=vm.runInNewContext(source,{document,window});
  factory(value=>replies.push(value),value=>{if(!allowed)return false;if(value)controller=value;return true;});
  function event(type,extra={}){let stopped=false;const e={target,isTrusted:true,...extra,preventDefault(){stopped=true;},stopImmediatePropagation(){stopped=true;}};handlers.get(type)?.(e);return stopped;}
  return {root,document,handlers,windows,replies,target,event,get controller(){return controller;},revoke(){allowed=false;}};
}
{
 const f=fixture();assert.equal(f.root.style.cursor,'crosshair');assert.equal(f.event('click',{isTrusted:false}),false);assert.equal(f.replies.length,0);assert.equal(f.event('click'),true);
 assert.deepEqual(f.replies,['#chosen']);assert.equal(f.root.style.cursor,'help');assert.equal(f.handlers.size,0);assert.equal(f.windows.size,0);
 f.controller.stop();assert.equal(f.replies.length,1);
}
for(const action of ['cancel','escape','hidden','pagehide']){
 const f=fixture();
 if(action==='cancel')f.controller.stop();
 if(action==='escape')f.event('keydown',{key:'Escape'});
 if(action==='hidden'){f.document.visibilityState='hidden';f.event('visibilitychange');}
 if(action==='pagehide')f.windows.get('pagehide')();
 assert.equal(f.root.style.cursor,'help');assert.equal(f.handlers.size,0);assert.equal(f.windows.size,0);
 assert.deepEqual(f.replies,action==='cancel'?[]:['']);
}
{
 const f=fixture(); f.target.id='x'.repeat(4096);f.target.localName='x'.repeat(4096);f.event('click');
 assert.deepEqual(f.replies,['']);assert.equal(f.handlers.size,0);
}
{
 // An install cancelled while Blink is paused cannot acquire document handlers.
 const handlers=new Map();let called=false;
 const factory=vm.runInNewContext(source,{document:{},window:{}});
 factory(()=>called=true,()=>false);assert.equal(called,false);assert.equal(handlers.size,0);
}
console.log('Boost picker fixed-controller lifecycle PASS');
