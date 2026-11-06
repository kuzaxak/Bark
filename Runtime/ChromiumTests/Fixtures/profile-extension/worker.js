const workerInstance = crypto.randomUUID();

// Store bounded event records so a restart or worker suspension does not erase
// the observations. Synthetic profiles only: tabs permission exposes tab URLs.
async function record(type, details) {
  const {events = [], droppedEvents = 0} = await chrome.storage.local.get(['events', 'droppedEvents']);
  const next = [...events, {type, details}];
  await chrome.storage.local.set({events: next.slice(-50),
    droppedEvents: droppedEvents + Math.max(0, next.length - 50)});
}
let pending = Promise.resolve();
function enqueue(type, details) {
  pending = pending.then(() => record(type, details));
}
chrome.tabs.onCreated.addListener(tab => enqueue('tab-created', {id: tab.id, windowId: tab.windowId, active: tab.active, url: tab.pendingUrl ?? tab.url}));
chrome.tabs.onRemoved.addListener((id, info) => enqueue('tab-removed', {id, windowId: info.windowId, isWindowClosing: info.isWindowClosing}));
chrome.tabs.onActivated.addListener(info => enqueue('tab-activated', {id: info.tabId, windowId: info.windowId, active: true}));
chrome.windows.onCreated.addListener(window => enqueue('window-created', {id: window.id, incognito: window.incognito, focused: window.focused, state: window.state}));
chrome.windows.onRemoved.addListener(id => enqueue('window-removed', {id}));
chrome.windows.onFocusChanged.addListener(id => enqueue('window-focus-changed', {id, none: id === chrome.windows.WINDOW_ID_NONE}));
chrome.runtime.onInstalled.addListener(details => enqueue('installed', details));
chrome.runtime.onStartup.addListener(() => enqueue('startup', {}));
function windowState(window) {
  return {id: window.id, incognito: window.incognito, focused: window.focused, state: window.state};
}
async function windowResult(query) {
  try {
    return {window: windowState(await query())};
  } catch (error) {
    return {error: error.message};
  }
}
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!['profile-probe', 'native-probe', 'reset-observations'].includes(message.type)) return;
  (async () => {
    if (message.type === 'reset-observations') {
      const observationId = crypto.randomUUID();
      pending = pending.then(() => chrome.storage.local.set({events: [], droppedEvents: 0, observationId}));
      await pending;
      reply({observationId});
      return;
    }
    if (message.type === 'native-probe') {
      const {marker} = await chrome.storage.local.get('marker');
      try {
        reply({response: await chrome.runtime.sendNativeMessage(message.host, {echo: marker})});
      } catch (error) {
        reply({error: error.message});
      }
      return;
    }
    await pending;
    const {marker = null, events = [], droppedEvents = 0, observationId = null} =
      await chrome.storage.local.get(['marker', 'events', 'droppedEvents', 'observationId']);
    const tabs = await chrome.tabs.query({});
    const windows = await chrome.windows.getAll();
    const currentWindow = await windowResult(() => chrome.windows.getCurrent());
    const lastFocusedWindow = await windowResult(() => chrome.windows.getLastFocused());
    reply({marker, events, droppedEvents, observationId, workerInstance, extensionId: chrome.runtime.id,
      windowIdNone: chrome.windows.WINDOW_ID_NONE, currentWindow, lastFocusedWindow,
      tabs: tabs.map(tab => ({id: tab.id, windowId: tab.windowId, active: tab.active, url: tab.url, incognito: tab.incognito})),
      windows: windows.map(windowState)});
  })().catch(error => reply({error: error.message}));
  return true;
});
