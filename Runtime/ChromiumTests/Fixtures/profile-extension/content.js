// Only the top document needs the existing enumeration/storage probe.
if (window.top === window) chrome.runtime.sendMessage({type: 'profile-probe'}).then(result => {
  document.documentElement.dataset.barcExtensionProbe = JSON.stringify(result);
});
// The worker takes all identity fields from MessageSender, never page data.
(async () => {
  const role = document.documentElement.dataset.barcFrameRole;
  if (!['top', 'same-origin', 'cross-origin'].includes(role)) return;
  const nonce = crypto.randomUUID();
  const received = await chrome.runtime.sendMessage({type: 'frame-probe', nonce, role});
  if (!received || received.error || received.nonce !== nonce) throw new Error(received?.error ?? 'frame response absent');
  const ack = await chrome.runtime.sendMessage({type: 'frame-probe-ack', nonce, received});
  if (!ack?.acknowledged || ack.nonce !== nonce) throw new Error(ack?.error ?? 'frame acknowledgement absent');
  document.documentElement.dataset.barcFrameProbe = JSON.stringify(received);
})().catch(error => document.documentElement.dataset.barcFrameProbe = JSON.stringify({error: error.message}));
