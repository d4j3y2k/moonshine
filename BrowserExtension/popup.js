const api = globalThis.browser || globalThis.chrome;
api.storage.local.get("status").then(({status}) => document.querySelector("#status").textContent = status || "Not connected");
document.querySelector("#connect").addEventListener("click", async () => {
  const token = document.querySelector("#token").value.trim();
  if (!/^[a-f0-9]{64}$/.test(token)) { document.querySelector("#status").textContent = "Paste the complete pairing code from Moonshine."; return; }
  await api.storage.local.set({token});
  await api.runtime.sendMessage("sync");
  document.querySelector("#token").value = "";
  document.querySelector("#status").textContent = "Connecting…";
});

let currentTab, currentOrigin;
const contextView = document.querySelector("#context");
async function updateSite() {
  [currentTab] = await api.tabs.query({active: true, currentWindow: true});
  currentOrigin = currentTab?.incognito === false ? MoonshinePageContext.origin(currentTab.url) : null;
  const {contextSites = []} = await api.storage.local.get("contextSites");
  const enabled = currentOrigin && contextSites.includes(currentOrigin);
  document.querySelector("#site").textContent = currentOrigin ? new URL(currentTab.url).host + (enabled ? " · enabled" : " · titles and URLs only") : "Page context is unavailable for this tab.";
  document.querySelector("#enable").disabled = !currentOrigin || enabled;
  document.querySelector("#disable").disabled = !enabled;
  document.querySelector("#preview").disabled = !enabled;
}
async function preview() {
  contextView.textContent = "Reading permitted page labels…";
  try {
    const result = await api.runtime.sendMessage({type: "context-preview", tabID: currentTab.id});
    const p = result?.page;
    contextView.textContent = p ? [p.siteName, p.summary, p.headings.length ? "Headings: " + p.headings.join(" · ") : "", p.controls.length ? "Controls: " + p.controls.join(" · ") : ""].filter(Boolean).join("\n\n") || "No useful labels found on this page." : "No context available. The page may be loading, restricted, or awaiting website permission.";
  } catch { contextView.textContent = "Context is unavailable. Reload the extension and try again."; }
}
document.querySelector("#enable").addEventListener("click", () => {
  if (!currentOrigin) return;
  const origin = currentOrigin;
  // The permission dialog can close this popup. The background completes the saved
  // intent when Chrome reports the grant, without expanding to any other site.
  const pending = api.storage.local.set({pendingContextSite: {origin, requestedAt: Date.now()}});
  api.permissions.request({permissions: ["scripting"], origins: [origin]}).then(async granted => {
    await pending;
    if (!granted) { contextView.textContent = "Website permission was not granted."; return; }
    const {contextSites = []} = await api.storage.local.get("contextSites");
    await api.storage.local.set({contextSites: [...new Set([...contextSites, origin])], pendingContextSite: null});
    await api.runtime.sendMessage("sync"); await updateSite(); await preview();
  }).catch(() => { contextView.textContent = "Unable to request website access. Check the browser's extension settings."; });
});
document.querySelector("#disable").addEventListener("click", async () => {
  const origin = currentOrigin;
  const {contextSites = []} = await api.storage.local.get("contextSites");
  await api.storage.local.set({contextSites: contextSites.filter(value => value !== origin)});
  // Keep localhost pairing permission; the local allowlist separately excludes this site.
  if (origin !== "http://127.0.0.1/*") await api.permissions.remove({origins: [origin]}).catch(() => {});
  await api.runtime.sendMessage("sync"); contextView.textContent = "This site's page context has been cleared."; await updateSite();
});
document.querySelector("#preview").addEventListener("click", preview);
updateSite().catch(() => { contextView.textContent = "Unable to inspect the current tab."; });
