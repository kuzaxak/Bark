(function(send,install){
  'use strict';
  if(!install())return;
  const root=document.documentElement;
  if(!root||document.visibilityState==='hidden'){send('');return;}
  const box=document.createElement('div');
  box.style.cssText='position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff4d4f;background:rgba(255,77,79,.18);border-radius:4px;display:none';
  const cursor=root.style.cursor;
  let live=true;
  function stop(){
    if(!live)return;live=false;
    for(const [type,fn] of events)document.removeEventListener(type,fn,true);
    window.removeEventListener('pagehide',cancel,true);
    box.remove();
    if(root.style.cursor==='crosshair')root.style.cursor=cursor;
  }
  function done(value){if(!live)return;stop();send(value);}
  function cancel(){done('');}
  function selector(el){
    const parts=[];
    for(let depth=0;el&&el!==root&&depth<32;depth++,el=el.parentElement){
      if(el.id&&/^[A-Za-z][\w-]{0,127}$/.test(el.id)&&document.querySelectorAll('#'+el.id).length===1){parts.unshift('#'+el.id);break;}
      let part=el.localName;
      if(!part||!/^[-a-zA-Z0-9]+$/.test(part))return '';
      const parent=el.parentElement;
      if(parent){let index=0,count=0;for(const child of parent.children){if(child.localName===el.localName){count++;if(child===el)index=count;}}if(count>1)part+=':nth-of-type('+index+')';}
      parts.unshift(part);
      const value=parts.join('>');
      if(value.length>2048)return '';
      if(document.querySelectorAll(value).length===1)return value;
    }
    const value=parts.join('>');
    return value.length<=2048&&document.querySelectorAll(value).length===1?value:'';
  }
  function eligible(el){return el&&el.nodeType===1&&el!==root&&el!==document.body&&el!==box;}
  const events=[
    ['mousemove',function(e){if(!eligible(e.target)){box.style.display='none';return;}const rect=e.target.getBoundingClientRect();Object.assign(box.style,{display:'block',left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});} ],
    ['click',function(e){if(!e.isTrusted)return;e.preventDefault();e.stopImmediatePropagation();done(eligible(e.target)?selector(e.target):'');}],
    ['keydown',function(e){if(e.isTrusted&&e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();cancel();}}],
    ['visibilitychange',function(){if(document.visibilityState==='hidden')cancel();}]
  ];
  // Native retains this controller only for the exact initiating document.
  const controller={stop};
  if(!install(controller)){stop();return;}
  root.appendChild(box);root.style.cursor='crosshair';
  for(const [type,fn] of events)document.addEventListener(type,fn,true);
  window.addEventListener('pagehide',cancel,true);
})
