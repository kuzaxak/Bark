// Run in this fixture's popup/options document after ordinary installation.
// Native host must first establish UUID -> Chrome Profile -> target ownership.
// These assertions do not establish that binding or native UI behavior.
globalThis.assertProfileFixture = async ({marker, requiredURLs = [], forbiddenURLs = [], forbiddenTabIds = [], forbiddenWindowIds = [], previousWorkerInstance, optionalOriginGranted, observationId, expectedEvents, expectedFocusSequence, expectedCurrentWindow, expectedLastFocusedWindow, assertStableTabsAndWindows = false, expectedTabIds, expectedWindowIds, expectedActiveTabs, expectedCommands}) => {
  const result = await chrome.runtime.sendMessage({type: 'profile-probe'});
  function require(condition, label) {
    if (!condition) throw new Error(label);
  }
  require(!result.error, result.error);
  require(result.droppedEvents === 0, 'event history incomplete; reset and repeat a smaller observation window');
  if (expectedEvents !== undefined || expectedFocusSequence !== undefined || expectedCommands !== undefined) {
    require(typeof observationId === 'string' && observationId.length > 0 && result.observationId === observationId, 'observation reset does not match');
  }
  if (expectedEvents !== undefined) {
    require(expectedEvents.some(event => event.type.startsWith('tab-')) && expectedEvents.some(event => event.type.startsWith('window-')), 'positive tab and window event expectations required');
    require(expectedEvents.every(expected => result.events.some(event => event.type === expected.type && Object.entries(expected).every(([key, value]) => key === 'type' || event.details[key] === value))), 'expected own-profile event absent');
    require(forbiddenTabIds.length > 0 && forbiddenWindowIds.length > 0, 'foreign tab and window IDs required for event isolation');
  }
  if (expectedFocusSequence !== undefined) {
    require(Array.isArray(expectedFocusSequence) && expectedFocusSequence.length > 0 && expectedFocusSequence.every(Number.isInteger), 'nonempty integer focus sequence required');
    require(result.windowIdNone === chrome.windows.WINDOW_ID_NONE && expectedFocusSequence.includes(result.windowIdNone), 'focus sequence must include WINDOW_ID_NONE');
    require(expectedFocusSequence.some(id => id > 0 && result.windows.some(window => window.id === id) && !forbiddenWindowIds.includes(id)), 'focus sequence must include an own window');
    require(forbiddenTabIds.length > 0 && forbiddenWindowIds.length > 0 && [...forbiddenTabIds, ...forbiddenWindowIds].every(id => Number.isInteger(id) && id > 0), 'real foreign tab and window IDs required for focus isolation');
    const focusIds = result.events.filter(event => event.type === 'window-focus-changed').map(event => event.details.id);
    require(JSON.stringify(focusIds) === JSON.stringify(expectedFocusSequence), 'logical window focus sequence differs');
  }
  if (expectedCommands !== undefined) {
    require(Array.isArray(expectedCommands) && expectedCommands.every(command => typeof command === 'string' && command.length > 0), 'exact command-name array required');
    require(forbiddenTabIds.length > 0 && forbiddenWindowIds.length > 0 && [...forbiddenTabIds, ...forbiddenWindowIds].every(id => Number.isInteger(id) && id > 0), 'real foreign tab and window IDs required for command isolation');
    const commands = result.events.filter(event => event.type === 'command').map(event => event.details.command);
    require(JSON.stringify(commands) === JSON.stringify(expectedCommands), 'command routing sequence differs');
  }
  require(!result.events.some(event => event.type === 'command' && (forbiddenTabIds.includes(event.details.tabId) || forbiddenWindowIds.includes(event.details.windowId))), 'foreign tab/window in command event');
  function sameIds(actual, expected) {
    return Array.isArray(expected) && expected.length > 0 && expected.every(Number.isInteger) &&
      new Set(expected).size === expected.length && actual.length === expected.length &&
      actual.every(id => expected.includes(id));
  }
  if (assertStableTabsAndWindows) {
    require(expectedFocusSequence !== undefined, 'stable switch check requires focus expectations');
    require(sameIds(result.tabs.map(tab => tab.id), expectedTabIds), 'tab IDs changed across switch');
    require(sameIds(result.windows.map(window => window.id), expectedWindowIds), 'window IDs changed across switch');
    require(Array.isArray(expectedActiveTabs) && expectedActiveTabs.length > 0, 'active tab/window snapshot required');
    require(!result.events.some(event => ['tab-created', 'tab-removed', 'tab-activated', 'window-created', 'window-removed'].includes(event.type)), 'synthetic lifecycle/activation during pure switch');
  }
  if (expectedActiveTabs !== undefined) {
    const active = result.tabs.filter(tab => tab.active);
    require(Array.isArray(expectedActiveTabs) && active.length === expectedActiveTabs.length && new Set(expectedActiveTabs.map(tab => tab.id)).size === expectedActiveTabs.length &&
      expectedActiveTabs.every(expected => Number.isInteger(expected.id) && Number.isInteger(expected.windowId) && active.some(tab => tab.id === expected.id && tab.windowId === expected.windowId)), 'active tab/window snapshot differs');
  }
  for (const [actual, expected, label] of [[result.currentWindow, expectedCurrentWindow, 'getCurrent'], [result.lastFocusedWindow, expectedLastFocusedWindow, 'getLastFocused']]) {
    if (expected !== undefined) {
      if (Object.hasOwn(expected, 'error')) {
        require(actual.error === expected.error && !actual.window, label + ' error differs');
      } else {
        require(!actual.error && actual.window && Object.entries(expected).every(([key, value]) => actual.window[key] === value), label + ' window differs');
      }
    }
    require(!actual.window || !forbiddenWindowIds.includes(actual.window.id), label + ' returned foreign window');
  }
  require(result.events.every(event => event.type !== 'window-focus-changed' || event.details.none === (event.details.id === result.windowIdNone)), 'WINDOW_ID_NONE indistinguishable');
  require(!result.tabs.some(tab => forbiddenWindowIds.includes(tab.windowId) || forbiddenTabIds.includes(tab.id)), 'foreign tab enumeration');
  require(!result.windows.some(window => forbiddenWindowIds.includes(window.id)), 'foreign window enumeration');
  require(result.marker === marker, 'extension storage marker differs');
  require(requiredURLs.every(url => result.tabs.some(tab => tab.url === url)), 'shared profile tab absent');
  require(forbiddenURLs.every(url => !result.tabs.some(tab => tab.url === url)), 'foreign profile/private tab visible');
  require(!result.tabs.some(tab => tab.incognito), 'private tab visible');
  require(!result.windows.some(window => window.incognito), 'private window visible');
  require(!result.events.some(event => event.type.startsWith('tab-') && forbiddenTabIds.includes(event.details.id)), 'foreign tab event');
  require(!result.events.some(event => event.type.startsWith('tab-') && forbiddenWindowIds.includes(event.details.windowId)), 'foreign window ID in tab event');
  require(!result.events.some(event => event.type.startsWith('window-') && forbiddenWindowIds.includes(event.details.id)), 'foreign window event');
  if (typeof optionalOriginGranted === 'boolean') {
    const granted = await chrome.permissions.contains({origins: ['https://example.com/*']});
    require(granted === optionalOriginGranted, 'optional host grant differs');
  }
  if (previousWorkerInstance) require(result.workerInstance !== previousWorkerInstance, 'worker did not restart');
  return result;
};
