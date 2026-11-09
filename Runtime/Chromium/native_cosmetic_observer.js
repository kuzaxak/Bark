// Native generic cosmetic discovery. This isolated-world closure has no URL or
// script transport. Caps: 4096 tokens/128KiB, 16384 visited elements, 64 queued
// roots, 128 classes per element, 32768 name checks. Queue overflow permits one document rescan
// under the same visit budget; repeated overflow stops discovery. Other caps stop;
// URL-specific CSS remains active. One native batch is outstanding at a time.
(function (send) {
  'use strict';
  const MAX_TOKENS=4096, MAX_BYTES=131072, MAX_VISITS=16384, MAX_ROOTS=64;
  const seenClasses=new Set(), seenIds=new Set(), roots=[], queuedRoots=new Set();
  const encoder=new TextEncoder();
  let bytes=0, visits=0, attempts=0, queued=false, inFlight=false, stopped=false, capped=false;
  let overflowRescanned=false;
  let walker=null, pendingClasses=[], pendingIds=[], pendingBytes=0;
  function stop() {
    stopped=true; inFlight=false; observer.disconnect(); roots.length=0; queuedRoots.clear();
    walker=null; pendingClasses=[]; pendingIds=[];
    seenClasses.clear(); seenIds.clear(); bytes=0; pendingBytes=0;
  }
  function schedule() {
    if (!stopped && !queued && !inFlight) { queued=true; queueMicrotask(drain); }
  }
  function rescan() {
    if (queuedRoots.has(document)) return;
    if (overflowRescanned) { capped=true; return; }
    overflowRescanned=true;
    roots.length=0; queuedRoots.clear(); roots.push(document); queuedRoots.add(document);
  }
  function enqueue(root) {
    if (stopped || !root || queuedRoots.has(root)) return;
    // A bounded queued ancestor covers descendants, including an overflow
    // rescan. Do not start redundant overlapping subtree walks.
    for (const ancestor of roots) if (ancestor.contains(root)) return;
    for (let i=roots.length-1; i>=0; --i) {
      if (root.contains(roots[i])) { queuedRoots.delete(roots[i]); roots.splice(i,1); }
    }
    if (roots.length>=MAX_ROOTS) {
      rescan(); return;
    }
    roots.push(root); queuedRoots.add(root);
  }

  function token(name, seen, pending) {
    if (!name) return;
    if (++attempts>32768) { capped=true; return; }
    if (name.length>512 || seen.has(name)) return;
    const size=encoder.encode(name).length;
    if (size>512 || capped) return;
    if (bytes+size>MAX_BYTES || seenClasses.size+seenIds.size>=MAX_TOKENS) { capped=true; return; }
    seen.add(name); pending.push({name,size}); bytes+=size; pendingBytes+=size;
  }
  function element(node) {
    if (node.nodeType!==Node.ELEMENT_NODE) return;
    const list=node.classList;
    for (let i=0; i<Math.min(list.length,128); ++i) token(list.item(i),seenClasses,pendingClasses);
    token(node.id,seenIds,pendingIds);
  }
  function exhausted() { return capped || visits>=MAX_VISITS || seenClasses.size+seenIds.size>=MAX_TOKENS || bytes>=MAX_BYTES; }
  function drain() {
    queued=false;
    if (stopped || inFlight) return;
    let work=0;
    while (work++<256 && !exhausted() && pendingClasses.length+pendingIds.length<128 && pendingBytes<15872) {
      if (!walker) {
        if (!roots.length) break;
        const root=roots.shift(); queuedRoots.delete(root);
        walker=document.createTreeWalker(root,NodeFilter.SHOW_ELEMENT);
        element(root); ++visits;
      } else {
        const node=walker.nextNode();
        if (!node) { walker=null; continue; }
        element(node); ++visits;
      }
    }
    if (pendingClasses.length || pendingIds.length) {
      const classes=[], ids=[];
      let count=0, batchBytes=0;
      function take(pending, output) {
        while (pending.length && count<128 && batchBytes+pending[0].size<=16384) {
          const token=pending.shift(); output.push(token.name);
          ++count; batchBytes+=token.size; pendingBytes-=token.size;
        }
      }
      take(pendingClasses,classes); take(pendingIds,ids);
      inFlight=true;
      send(classes,ids,function (more) {
        if (stopped) return;
        inFlight=false;
        if (!more) { stop(); return; }
        schedule();
      });
    } else if (exhausted()) stop();
    else if (walker || roots.length) schedule();
  }
  const observer=new MutationObserver(function (records) {
    let work=0;
    outer: for (const record of records) {
      if (capped) break;
      if (++work>256) { rescan(); break; }
      if (record.type==='attributes') enqueue(record.target);
      else {
        for (const node of record.addedNodes) {
          if (++work>256) { rescan(); break outer; }
          enqueue(node);
          if (capped) break outer;
        }
      }
    }
    schedule();
  });
  observer.observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['class','id']});
  enqueue(document); schedule();
  return {stop};
})
