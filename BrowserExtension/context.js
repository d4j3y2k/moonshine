/* Executed only on explicitly enabled sites, in the top frame. Never reads input values. */
function collectPageContext() {
  if (!/^https?:$/.test(location.protocol) || document.contentType !== "text/html") return null;
  const clean = (text, size) => String(text || "").replace(/\s+/g, " ").trim().slice(0, size);
  const visible = el => {
    if (!el || el.closest('form,input,textarea,select,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"]')) return false;
    const style = getComputedStyle(el);
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0" && el.getClientRects().length > 0;
  };
  const documents = [document];
  // Embedded tools commonly live in same-origin or srcdoc frames. The DOM's origin
  // boundary prevents access to third-party frames; only visible approved-site views count.
  for (let index = 0; index < documents.length && documents.length < 4; index++) {
    for (const frame of Array.from(documents[index].querySelectorAll('iframe')).slice(0, 12)) {
      if (!visible(frame)) continue;
      try {
        const nested = frame.contentDocument;
        if (!nested || nested.contentType !== "text/html") continue;
        const nestedURL = new URL(nested.URL, location.href);
        if (nestedURL.origin !== new URL(location.href).origin && !["about:srcdoc", "about:blank"].includes(nested.URL)) continue;
        if (!documents.includes(nested)) documents.push(nested);
        if (documents.length >= 4) break;
      } catch { /* Cross-origin embedded views are outside the granted site's context. */ }
    }
  }
  const labels = (selector, count, length) => {
    const result = [], seen = new Set();
    for (const el of documents.flatMap(doc => Array.from(doc.querySelectorAll(selector)).slice(0, 100)).slice(0, 300)) {
      if (!visible(el)) continue;
      // Avoid including editable descendants in a surrounding button/heading's text.
      const editableChild = el.querySelector('input,textarea,select,[contenteditable]:not([contenteditable="false"])');
      const text = clean(el.getAttribute("aria-label") || (editableChild ? "" : el.innerText), length);
      if (selector.startsWith("h1") && !/\p{L}/u.test(text)) continue; // Scores and counters do not describe a page.
      if (text && !seen.has(text)) { result.push(text); seen.add(text); }
      if (result.length >= count) break;
    }
    return result;
  };
  const meta = selector => [...new Set(documents.map(doc => doc.querySelector(selector)?.getAttribute("content") || "").filter(Boolean))].join(" · ");
  return {
    sourceURL: location.href, capturedAt: Date.now() / 1000,
    siteName: clean(meta('meta[property="og:site_name"]') || meta('meta[name="application-name"]'), 80),
    summary: clean(meta('meta[name="description"]') || meta('meta[property="og:description"]'), 400),
    headings: labels('h1,h2,h3,[role="heading"]', 6, 80),
    controls: labels('button,[role="button"],[role="tab"]', 10, 40)
  };
}

function pageOrigin(url) {
  try {
    const value = new URL(url);
    return /^https?:$/.test(value.protocol) && !value.username && !value.password ? value.origin + "/*" : null;
  } catch { return null; }
}
globalThis.MoonshinePageContext = { collect: collectPageContext, origin: pageOrigin };
