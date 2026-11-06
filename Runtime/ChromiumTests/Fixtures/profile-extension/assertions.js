// Run in this fixture's popup/options document after ordinary installation.
// Native host must first establish UUID -> Chrome Profile -> target ownership.
// These assertions do not establish that binding or native UI behavior.
globalThis.assertProfileFixture = async ({marker, requiredURLs = [], forbiddenURLs = [], forbiddenTabIds = [], forbiddenWindowIds = [], previousWorkerInstance, optionalOriginGranted, observationId, expectedEvents}) => {
  const result = await chrome.runtime.sendMessage({type: 'profile-probe'});
  function require(condition, label) {
    if (!condition) throw new Error(label);
  }
  require(!result.error, result.error);
  require(result.droppedEvents === 0, 'event history incomplete; reset and repeat a smaller observation window');
  if (expectedEvents !== undefined) {
    require(typeof observationId === 'string' && result.observationId === observationId, 'observation reset does not match');
    require(expectedEvents.some(event => event.type.startsWith('tab-')) && expectedEvents.some(event => event.type.startsWith('window-')), 'positive tab and window event expectations required');
    require(expectedEvents.every(expected => result.events.some(event => event.type === expected.type && event.details.id === expected.id)), 'expected own-profile event absent');
    require(forbiddenTabIds.length > 0 && forbiddenWindowIds.length > 0, 'foreign tab and window IDs required for event isolation');
  }
  require(result.marker === marker, 'extension storage marker differs');
  require(requiredURLs.every(url => result.tabs.some(tab => tab.url === url)), 'shared profile tab absent');
  require(forbiddenURLs.every(url => !result.tabs.some(tab => tab.url === url)), 'foreign profile/private tab visible');
  require(!result.tabs.some(tab => tab.incognito), 'private tab visible');
  require(!result.windows.some(window => window.incognito), 'private window visible');
  require(!result.events.some(event => event.type.startsWith('tab-') && forbiddenTabIds.includes(event.details.id)), 'foreign tab event');
  require(!result.events.some(event => event.type.startsWith('window-') && forbiddenWindowIds.includes(event.details.id)), 'foreign window event');
  if (typeof optionalOriginGranted === 'boolean') {
    const granted = await chrome.permissions.contains({origins: ['https://example.com/*']});
    require(granted === optionalOriginGranted, 'optional host grant differs');
  }
  if (previousWorkerInstance) require(result.workerInstance !== previousWorkerInstance, 'worker did not restart');
  return result;
};
