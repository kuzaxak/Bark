const workerInstance = crypto.randomUUID();
// Bounded, one-use receipts. A worker restart invalidates unfinished probes.
const frameReceipts = new Map();
function frameIdentity(sender) {
  if (sender.id !== chrome.runtime.id || !sender.tab || sender.tab.incognito !== false ||
      !Number.isInteger(sender.tab.id) || sender.tab.id <= 0 || !Number.isInteger(sender.tab.windowId) || sender.tab.windowId <= 0 ||
      !Number.isInteger(sender.frameId) || sender.frameId < 0 || typeof sender.documentId !== "string" || !sender.documentId ||
      sender.origin !== new URL(sender.url).origin) throw new Error("real regular-frame sender identity required");
  return {extensionId: sender.id, tabId: sender.tab.id, windowId: sender.tab.windowId,
    frameId: sender.frameId, documentId: sender.documentId, origin: sender.origin, url: sender.url};
}

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
chrome.commands.onCommand.addListener((command, tab) => enqueue('command', {command, tabId: tab?.id, windowId: tab?.windowId}));
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
  if (!['profile-probe', 'native-probe', 'reset-observations', 'frame-probe', 'frame-probe-ack'].includes(message.type)) return;
  (async () => {
    if (message.type === 'frame-probe') {
      const identity = frameIdentity(sender);
      if (typeof message.nonce !== 'string' || !message.nonce || frameReceipts.has(message.nonce) || frameReceipts.size >= 50) throw new Error('invalid or excess pending frame probe');
      await pending;
      const {marker = null, observationId = null} = await chrome.storage.local.get(['marker', 'observationId']);
      if (!observationId) throw new Error('reset observations before loading frame fixtures');
      const receipt = {...identity, nonce: message.nonce, role: message.role, marker, observationId, workerInstance};
      if (frameReceipts.has(message.nonce) || frameReceipts.size >= 50) throw new Error("duplicate or excess pending frame probe");
      frameReceipts.set(message.nonce, receipt);
      reply(receipt);
      return;
    }
    if (message.type === 'frame-probe-ack') {
      const identity = frameIdentity(sender);
      const receipt = frameReceipts.get(message.nonce);
      if (!receipt || !Object.entries(identity).every(([key, value]) => receipt[key] === value) ||
          !message.received || !Object.entries(receipt).every(([key, value]) => message.received[key] === value)) throw new Error('frame receipt or sender changed');
      frameReceipts.delete(message.nonce);
      enqueue('frame-roundtrip', receipt);
      await pending;
      reply({acknowledged: true, nonce: message.nonce});
      return;
    }
    if (message.type === 'reset-observations') {
      frameReceipts.clear();
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
