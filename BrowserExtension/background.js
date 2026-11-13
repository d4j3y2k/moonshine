/* Opt-in page labels only. No screenshots, history, private tabs, or remote services. */
if (typeof importScripts === "function") importScripts("context.js");
const api = globalThis.browser || globalThis.chrome;
const pageCache = new Map();
const attempted = new Map();
let contextEpoch = 0;
let contextWork;
function refreshContext(tabs) {
  if (!contextWork) contextWork = contextForTabs(tabs).catch(() => {}).finally(() => { contextWork = null; });
  return contextWork;
}

async function contextForTabs(tabs) {
  const { contextSites = [] } = await api.storage.local.get("contextSites");
  const allowed = new Set(Array.isArray(contextSites) ? contextSites : []);
  const epoch = contextEpoch;
  const live = new Set(tabs.map(t => t.id));
  for (const id of pageCache.keys()) if (!live.has(id)) pageCache.delete(id);
  for (const id of attempted.keys()) if (!live.has(id)) attempted.delete(id);
  let captures = 0;
  for (const tab of tabs) {
    const origin = globalThis.MoonshinePageContext?.origin(tab.url);
    if (!origin || !allowed.has(origin) || !api.scripting || !api.permissions || tab.discarded || tab.status === "loading") {
      pageCache.delete(tab.id); continue;
    }
    if (!await api.permissions.contains({ permissions: ["scripting"], origins: [origin] })) { pageCache.delete(tab.id); continue; }
    const cached = pageCache.get(tab.id);
    if (cached && cached.sourceURL !== tab.url) pageCache.delete(tab.id);
    if (cached?.sourceURL === tab.url && Date.now() / 1000 - cached.capturedAt < 20) continue;
    const attempt = attempted.get(tab.id);
    if (attempt?.url === tab.url && Date.now() - attempt.time < 20_000) continue;
    if (captures++ >= 4) continue;
    attempted.set(tab.id, { url: tab.url, time: Date.now() });
    try {
      const before = await api.tabs.get(tab.id);
      if (before.incognito !== false || before.url !== tab.url) { pageCache.delete(tab.id); continue; }
      let timeout, results;
      try {
        results = await Promise.race([
          api.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, func: MoonshinePageContext.collect }),
          new Promise((_, reject) => { timeout = setTimeout(() => reject(Error("Page capture timed out")), 1800); })
        ]);
      } finally { clearTimeout(timeout); }
      const current = await api.tabs.get(tab.id);
      const page = results.find(r => r.frameId === 0)?.result;
      if (epoch !== contextEpoch || current.incognito !== false || current.url !== tab.url || page?.sourceURL !== tab.url) {
        pageCache.delete(tab.id); continue;
      }
      if (page && Number.isFinite(page.capturedAt)) pageCache.set(tab.id, page);
    } catch { pageCache.delete(tab.id); }
  }
  if (epoch !== contextEpoch) pageCache.clear();
}
let busy = false;
let syncRequested = false;
let nextSync;
let acknowledgements = [];
let cachedSession;
const completed = new Map();
async function identity() {
  const { token, client } = await api.storage.local.get(["token", "client"]);
  if (!token) return null;
  const clientID = client || crypto.randomUUID();
  if (!client) await api.storage.local.set({ client: clientID });
  // Session storage survives worker suspension, but not a browser restart.
  // Older Safari without session storage deliberately gets a new identity on wake.
  if (!cachedSession) {
    const saved = api.storage.session ? await api.storage.session.get("session") : {};
    cachedSession = saved.session || crypto.randomUUID();
    if (api.storage.session) await api.storage.session.set({ session: cachedSession });
  }
  return { token, client: clientID, session: cachedSession };
}
async function sync() {
  if (busy) { syncRequested = true; return; }
  clearTimeout(nextSync);
  busy = true;
  syncRequested = false;
  let connected = false, continuous = false;
  try {
    const id = await identity();
    if (!id) return;
    const discovered = (await api.tabs.query({})).filter(t => t.incognito === false && Number.isInteger(t.id));
    refreshContext(discovered); // Capture never holds up inventory sync or activation acknowledgements.
    // Context is asynchronous and is attached only to its exact source URL.
    const tabs = discovered.map(t => ({
      id: t.id, windowId: t.windowId, title: t.title || "Untitled tab", url: t.url || "", incognito: false,
      pageContext: pageCache.get(t.id)?.sourceURL === t.url && Date.now() / 1000 - pageCache.get(t.id).capturedAt <= 120 ? pageCache.get(t.id) : undefined
    }));
    const ack = acknowledgements;
    const response = await fetch("http://127.0.0.1:49731/sync", {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${id.token}` },
      body: JSON.stringify({ client: id.client, session: id.session, transportVersion: 2,
        browser: /Safari/.test(navigator.userAgent) && !/Chrome/.test(navigator.userAgent) ? "Safari" : "Chrome", tabs, acknowledgements: ack }),
      signal: AbortSignal.timeout(4000)
    });
    if (!response.ok) throw new Error("Connection refused");
    const payload = await response.json();
    const commands = Array.isArray(payload) ? payload : payload.commands;
    if (!Array.isArray(commands)) throw new Error("Invalid response");
    acknowledgements = acknowledgements.filter(a => !ack.includes(a));
    continuous = payload.transportVersion === 2;
    connected = true;
    for (const command of commands.slice(0, 8)) {
      if (command.session !== id.session || !Number.isInteger(command.tabID) || typeof command.id !== "string" || !Number.isFinite(command.expiresAt) || Date.now() >= command.expiresAt) continue;
      if (completed.has(command.id)) { acknowledgements.push(completed.get(command.id)); continue; }
      let success = false;
      try {
        const tab = await api.tabs.get(command.tabID);
        if (tab.incognito !== false || Date.now() >= command.expiresAt) throw new Error("Private or expired tab");
        await api.tabs.update(tab.id, { active: true });
        // Resolve again after a possible tab move; never reuse an inventory index.
        const current = await api.tabs.get(tab.id);
        if (current.incognito !== false) throw new Error("Private tab excluded");
        await api.windows.update(current.windowId, { focused: true });
        const verified = await api.tabs.get(tab.id);
        success = verified.active && verified.incognito === false;
      } catch { /* Closed, moved into private scope, or browser refused. */ }
      const result = { id: command.id, success };
      completed.set(command.id, result); acknowledgements.push(result);
      if (completed.size > 100) completed.delete(completed.keys().next().value);
    }
    await api.storage.local.set({ status: "Connected · private tabs excluded" });
  } catch { await api.storage.local.set({ status: "Open Moonshine and check the pairing code." }); }
  finally {
    busy = false;
    // Flush acknowledgements and events raised while busy immediately. Successful
    // v2 requests reconnect to the bounded long poll with no interval-sized gap.
    // Failures retain acknowledgements and back off instead of spinning offline.
    nextSync = setTimeout(sync, connected && (continuous || syncRequested || acknowledgements.length) ? 0 : 1000);
  }
}
for (const event of [api.tabs.onCreated, api.tabs.onUpdated, api.tabs.onRemoved, api.tabs.onMoved,
                     api.tabs.onAttached, api.tabs.onDetached, api.tabs.onActivated, api.windows.onFocusChanged]) {
  event.addListener(() => sync());
}
api.runtime.onMessage.addListener((message, _sender, reply) => {
  if (message === "sync") { sync(); return; }
  if (message?.type === "context-preview" && Number.isInteger(message.tabID)) {
    (async () => {
      try {
        const tabs = (await api.tabs.query({})).filter(t => t.incognito === false && Number.isInteger(t.id));
        attempted.delete(message.tabID); pageCache.delete(message.tabID);
        await refreshContext(tabs);
        const current = await api.tabs.get(message.tabID), page = pageCache.get(message.tabID);
        reply({ page: current.incognito === false && page?.sourceURL === current.url ? page : null });
        sync();
      } catch { reply({ page: null }); }
    })();
    return true;
  }
});
api.tabs.onUpdated.addListener((id, change) => {
  if (change.url || change.status === "loading") { contextEpoch++; pageCache.delete(id); attempted.delete(id); }
});
api.tabs.onRemoved.addListener(id => { contextEpoch++; pageCache.delete(id); attempted.delete(id); });
api.permissions?.onRemoved.addListener(() => { contextEpoch++; pageCache.clear(); attempted.clear(); sync(); });
api.permissions?.onAdded?.addListener(async grant => {
  const { pendingContextSite: pending, contextSites = [] } = await api.storage.local.get(["pendingContextSite", "contextSites"]);
  if (!pending || Date.now() - pending.requestedAt > 120_000 || Date.now() < pending.requestedAt || !grant.origins?.includes(pending.origin)) return;
  if (!MoonshinePageContext.origin(pending.origin.slice(0, -1)) || !await api.permissions.contains({permissions: ["scripting"], origins: [pending.origin]})) return;
  await api.storage.local.set({contextSites: [...new Set([...contextSites, pending.origin])], pendingContextSite: null});
  sync();
});
api.storage.onChanged?.addListener((changes, area) => {
  if (area === "local" && changes.contextSites) { contextEpoch++; pageCache.clear(); attempted.clear(); sync(); }
});
api.alarms.create("moonshine", { periodInMinutes: 0.5 });
api.alarms.onAlarm.addListener(() => sync());
sync();
