async function refresh(increment) {
  const {clicks = 0} = await chrome.storage.local.get('clicks');
  if (increment) await chrome.storage.local.set({clicks: clicks + 1});
  document.querySelector('#result').textContent = String(clicks + Number(increment));
}
document.querySelector('#increment').onclick = () => refresh(true);
refresh(false);
