chrome.storage.local.get('marker').then(({marker = ''}) => document.querySelector('#marker').value = marker);
document.querySelector('#save').onclick = async () => {
  await chrome.storage.local.set({marker: document.querySelector('#marker').value});
  document.querySelector('#status').textContent = 'Saved';
};
document.querySelector('#grant').onclick = async () => {
  const granted = await chrome.permissions.request({origins: ['https://example.com/*']});
  document.querySelector('#status').textContent = granted ? 'Granted' : 'Denied';
};
