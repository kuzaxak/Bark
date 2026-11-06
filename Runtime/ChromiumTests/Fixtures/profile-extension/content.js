chrome.runtime.sendMessage({type: 'profile-probe'}).then(result => {
  document.documentElement.dataset.barcExtensionProbe = JSON.stringify(result);
});
