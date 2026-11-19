const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
class Events {
  listeners = new Map();
  addEventListener(name, fn) { if (!this.listeners.has(name)) this.listeners.set(name,new Set()); this.listeners.get(name).add(fn); }
  removeEventListener(name, fn) { this.listeners.get(name)?.delete(fn); }
  fire(name, event = {}) { for (const fn of [...(this.listeners.get(name)||[])]) fn(event); }
  count() { return [...this.listeners.values()].reduce((n,v)=>n+v.size,0); }
}
const source=fs.readFileSync(process.argv[2]||'Runtime/Chromium/bark/resources/nook_tweaks/youtube-sponsorblock.js','utf8');
const document=new Events(),window=new Events(),video=new Events();
Object.assign(video,{isConnected:true,duration:100,paused:true,ended:false,currentTime:0,playbackRate:1});
Object.assign(document,{readyState:'loading',querySelector:s=>s==='#movie_player video'?video:null});
const location={href:'https://www.youtube.com/watch?v=abcdefghijk'};
const requests=[],timeouts=new Map(),intervals=new Map();let next=0;
const context=vm.createContext({window,document,location,console:{log(){},warn(){}},performance:{now:()=>0},
 setTimeout:(fn)=>{timeouts.set(++next,fn);return next;},clearTimeout:id=>timeouts.delete(id),
 setInterval:(fn)=>{intervals.set(++next,fn);return next;},clearInterval:id=>intervals.delete(id),
 nookSponsorBlockNative:(video,uuid)=>requests.push({video,uuid})});
const controller=vm.runInContext(source,context);
assert.equal(requests.length,0);
document.fire('DOMContentLoaded');assert.deepEqual(requests,[{video:'abcdefghijk',uuid:''}]);
const segment={UUID:'a'.repeat(64),segment:[1,3],category:'sponsor',actionType:'skip'};
controller.receiveSegments([segment],{sponsor:'auto'},'abcdefghijk');assert.ok(video.count()>0);
location.href='https://www.youtube.com/watch?v=zzzzzzzzzzz';document.fire('yt-navigate-finish');
assert.equal(video.count(),0);assert.equal(requests.at(-1).video,'zzzzzzzzzzz');
controller.receiveSegments([segment],{sponsor:'auto'},'abcdefghijk');assert.equal(video.count(),0,'late video reply must not attach');
window.fire('popstate');assert.ok(timeouts.size>0);
controller.stop();assert.equal(document.count(),0);assert.equal(window.count(),0);assert.equal(video.count(),0);
assert.equal(timeouts.size,0);assert.equal(intervals.size,0);assert.equal(window.__nookSponsorBlock,undefined);
const count=requests.length;document.fire('yt-navigate-finish');controller.receiveSegments([segment],{sponsor:'auto'},'zzzzzzzzzzz');
assert.equal(video.count(),0);assert.equal(requests.length,count);
console.log('SponsorBlock script PASS: fixed request, late-video rejection, settings retirement, listeners/timers cleanup');
