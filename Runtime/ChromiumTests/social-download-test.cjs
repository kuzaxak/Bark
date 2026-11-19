const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
class Node {
 constructor(tag='DIV'){this.tagName=tag;this.listeners=new Map();this.style={};this.attrs={};this.isConnected=true;this.parentElement=null;}
 addEventListener(n,fn){if(!this.listeners.has(n))this.listeners.set(n,new Set());this.listeners.get(n).add(fn);}
 removeEventListener(n,fn){this.listeners.get(n)?.delete(fn);}
 fire(n,e={}){for(const fn of [...(this.listeners.get(n)||[])])fn(e);}
 count(){return [...this.listeners.values()].reduce((n,s)=>n+s.size,0);}
 setAttribute(n,v){this.attrs[n]=v;}
 getAttribute(n){return this.attrs[n]||null;}
 removeAttribute(n){delete this.attrs[n];}
 append(...nodes){nodes.forEach(n=>n.parentElement=this);}
 appendChild(n){n.parentElement=this;return n;}
 attachShadow(){return new Node();}
 remove(){this.isConnected=false;}
 getBoundingClientRect(){return {top:0,left:0,right:200,bottom:200,width:200,height:200};}
}
let button,host;const document=new Node(),window=new Node(),image=new Node('IMG');
image.src=image.currentSrc='https://cdn.test/image.png';image.naturalWidth=200;
document.body=new Node('BODY');image.parentElement=document.body;document.documentElement=new Node('HTML');
document.elementsFromPoint=()=>[image];document.createElement=tag=>{const n=new Node(tag.toUpperCase());if(tag==='button')button=n;if(tag==='div')host=n;return n;};document.createElementNS=(_,tag)=>new Node(tag);
let serial=0;const timers=new Map(),downloads=[];
const context=vm.createContext({document,window,location:{hostname:'a.test',href:'https://a.test/'},URL,innerWidth:800,
 NOOK_DOWNLOAD_SITES:['a.test'],nookSocialDownloadNative:url=>{downloads.push(url);return true;},
 setTimeout:fn=>{timers.set(++serial,fn);return serial;},clearTimeout:id=>timers.delete(id),getComputedStyle:()=>({overflow:'visible'})});
const control=vm.runInContext(fs.readFileSync('Runtime/Chromium/bark/resources/nook_tweaks/social-image-download.js','utf8'),context);
document.fire('mouseover',{clientX:180,clientY:20,target:image});assert.ok(button);
const click={clientX:180,clientY:20,preventDefault(){},stopPropagation(){}};
button.fire('click',{...click,isTrusted:false});assert.equal(downloads.length,0,'synthetic clicks carry no authority');
button.fire('click',{...click,isTrusted:true});assert.deepEqual(downloads,['https://cdn.test/image.png']);
window.fire('scroll',{target:document});assert.equal(timers.size,1);
control.stop();assert.equal(document.count(),0);assert.equal(window.count(),0);assert.equal(timers.size,0);assert.equal(host.isConnected,false);
button.fire('click',{...click,isTrusted:true});assert.equal(downloads.length,1,'retired controller cannot dispatch');
const pageDocument=new Node();const page=vm.createContext({document:pageDocument,location:{hostname:'www.facebook.com'}});
const reader=vm.runInContext(fs.readFileSync('Runtime/Chromium/bark/resources/nook_tweaks/social-video-source.js','utf8'),page);
assert.equal(pageDocument.count(),1);reader.stop();assert.equal(pageDocument.count(),0);
assert.equal('nookSocialDownloadNative' in page,false,'page data reader has no native capability');
console.log('Social script PASS: trusted-only fixed dispatch, retired controls/timer, removable page-world data listener');
