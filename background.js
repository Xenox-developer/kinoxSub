const STORAGE_KEY = "kinoxDualSubtitlesState";

const DEFAULT_STATE = {
  enabled: true,
  primary: { enabled: true, name: "", offset: 0, cues: [] },
  secondary: { enabled: true, name: "", offset: 0, cues: [] }
};
const frameReports = new Map();

function isKinoxTab(url) {
  try {
    const hostname = new URL(url).hostname.toLowerCase();
    return hostname === "kinox.to" || hostname.endsWith(".kinox.to");
  } catch {
    return false;
  }
}

async function readState() {
  const result = await chrome.storage.local.get(STORAGE_KEY);
  const state = result[STORAGE_KEY] || structuredClone(DEFAULT_STATE);
  let repaired = false;
  for (const slot of ["primary", "secondary"]) {
    if (Math.abs(Number(state[slot]?.offset || 0)) > 30) {
      state[slot].offset = 0;
      repaired = true;
    }
  }
  if (repaired) await chrome.storage.local.set({ [STORAGE_KEY]: state });
  return state;
}

function broadcastState(tabId, state) {
  chrome.tabs.sendMessage(tabId, { type: "KINOSUB_STATE", state }, () => {
    // It is normal for a newly created frame to disappear before delivery.
    void chrome.runtime.lastError;
  });
}

function broadcastDiagnostics(tabId) {
  const now = Date.now();
  const reports = frameReports.get(tabId) || new Map();
  const recent = [...reports.values()].filter((report) => now - report.timestamp < 10000);
  const diagnostics = {
    frames: recent.length,
    videos: recent.reduce((sum, report) => sum + report.videos, 0),
    visibleVideos: recent.reduce((sum, report) => sum + report.visibleVideos, 0),
    overlayRenderers: recent.reduce((sum, report) => sum + report.overlayRenderers, 0),
    errors: recent.flatMap((report) => report.errors || []).slice(-3)
  };

  chrome.tabs.sendMessage(tabId, { type: "KINOSUB_DIAGNOSTICS", diagnostics }, () => {
    void chrome.runtime.lastError;
  });
}

function broadcastAutoSync(tabId, message) {
  chrome.tabs.sendMessage(tabId, message, () => {
    void chrome.runtime.lastError;
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const allowed = Boolean(sender.tab && isKinoxTab(sender.tab.url));

  if (message?.type === "KINOSUB_CONTEXT_CHECK") {
    sendResponse({ allowed });
    return false;
  }

  if (!allowed) {
    sendResponse({ ok: false, error: "This tab is not a kinox.to page." });
    return false;
  }

  if (message?.type === "KINOSUB_GET_STATE") {
    readState()
      .then((state) => sendResponse({ ok: true, state }))
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  if (message?.type === "KINOSUB_REPORT") {
    if (!frameReports.has(sender.tab.id)) frameReports.set(sender.tab.id, new Map());
    frameReports.get(sender.tab.id).set(sender.frameId, {
      ...message.report,
      timestamp: Date.now()
    });
    broadcastDiagnostics(sender.tab.id);
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === "KINOSUB_AUTOSYNC_REQUEST") {
    broadcastAutoSync(sender.tab.id, {
      type: "KINOSUB_AUTOSYNC_START",
      requestId: message.requestId,
      duration: message.duration || 30
    });
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === "KINOSUB_AUTOSYNC_EVENT") {
    broadcastAutoSync(sender.tab.id, {
      type: "KINOSUB_AUTOSYNC_EVENT",
      requestId: message.requestId,
      event: message.event
    });
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === "KINOSUB_SAVE_STATE") {
    chrome.storage.local
      .set({ [STORAGE_KEY]: message.state })
      .then(() => {
        broadcastState(sender.tab.id, message.state);
        sendResponse({ ok: true });
      })
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => frameReports.delete(tabId));
