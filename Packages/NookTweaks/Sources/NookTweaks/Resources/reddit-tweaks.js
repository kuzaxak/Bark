// Nook Reddit Tweaks
(() => {
  if (!/^(www\.)?reddit\.com$/.test(location.hostname)) return;
  const feed = /^\/(r\/[^/]+\/|user\/[^/]+\/m\/[^/]+\/)?$/;
  document.addEventListener('click', (e) => {
    const a = e.composedPath().find((n) => n instanceof HTMLAnchorElement && n.href);
    if (!a) return;
    const u = new URL(a.href);
    const path = u.pathname.endsWith('/') ? u.pathname : u.pathname + '/';
    if (u.host !== location.host || !feed.test(path)) return;
    u.pathname = path + 'hot/';
    a.href = u.href;
  }, true);
})();
