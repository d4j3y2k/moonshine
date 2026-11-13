const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const contextSource = fs.readFileSync(__dirname + '/context.js', 'utf8');
const backgroundSource = fs.readFileSync(__dirname + '/background.js', 'utf8');
const tick = async () => { for (let i = 0; i < 20; i++) await new Promise(r => setImmediate(r)); };

async function harness(options = {}) {
  const listeners = {}, snapshots = [], captured = [];
  let tab = {id: 7, windowId: 3, title: 'Chordbook', url: 'https://example.org/chordbook', incognito: false, status: 'complete', ...options.tab};
  let sites = options.enabled === false ? [] : ['https://example.org/*'];
  let permitted = options.permitted !== false;
  const event = name => ({addListener(fn) { (listeners[name] ||= []).push(fn); }});
  const api = {
    storage: {local: {get: async () => ({token: 'a'.repeat(64), client: 'client', contextSites: sites}), set: async () => {}},
      session: {get: async () => ({session: 'session'}), set: async () => {}}, onChanged: event('storage')},
    tabs: {query: async () => tab ? [tab] : [], get: async () => { if (!tab) throw Error('closed'); return {...tab}; }, update: async () => {}},
    windows: {onFocusChanged: event('focus')},
    permissions: {contains: async () => permitted, onRemoved: event('permissions')},
    scripting: {executeScript: async request => {
      captured.push(request);
      if (options.slow) return new Promise(() => {});
      const url = tab.url;
      if (options.navigate) tab = {...tab, url: 'https://example.org/another-page'};
      if (options.becomePrivate) tab = {...tab, incognito: true};
      return [{frameId: 0, result: {sourceURL: url, capturedAt: Date.now()/1000, siteName: 'Example', summary: 'A piano tool', headings: ['Keyboard'], controls: ['Play']}}];
    }},
    runtime: {onMessage: event('message')}, alarms: {create(){}, onAlarm: event('alarm')}
  };
  for (const e of ['onCreated','onUpdated','onRemoved','onMoved','onAttached','onDetached','onActivated']) api.tabs[e] = event(e);
  const context = vm.createContext({chrome: api, navigator: {userAgent: 'Chrome'}, URL, crypto: require('node:crypto').webcrypto, AbortSignal,
    setInterval(){}, setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); t.unref(); return t; }, clearTimeout,
    fetch: async (_, request) => { snapshots.push(JSON.parse(request.body)); return {ok: true, json: async () => []}; }});
  vm.runInContext(contextSource, context); vm.runInContext(backgroundSource, context); await tick();
  await vm.runInContext('sync()', context); await tick();
  return {context, snapshots, captured, debug: vm.runInContext("JSON.stringify({busy, cache: [...pageCache], attempted: [...attempted]})", context), async revoke() { permitted = false; sites = []; for (const fn of listeners.permissions || []) fn(); await tick(); await vm.runInContext('sync()', context); }};
}

test('page capture requires site opt-in, permission, and explicit ordinary-tab status', async () => {
  for (const options of [{enabled:false}, {permitted:false}, {tab:{incognito:true}}, {tab:{incognito:undefined}}, {tab:{discarded:true}}, {tab:{url:'file:///private.txt'}}]) {
    const h = await harness(options); assert.equal(h.captured.length, 0);
    assert.ok(h.snapshots.every(s => s.tabs.every(t => !t.pageContext)));
  }
});
test('only current approved page context accompanies the tab; permission removal clears it', async () => {
  const h = await harness();
  assert.equal(h.captured.length, 1);
  assert.deepEqual(Array.from(h.captured[0].target.frameIds), [0]);
  assert.equal(h.snapshots.at(-1)?.tabs[0]?.pageContext?.summary, 'A piano tool', h.debug);
  await h.revoke(); assert.equal(h.snapshots.at(-1).tabs[0].pageContext, undefined);
});
test('navigation or private transition during capture rejects the snapshot', async () => {
  for (const options of [{navigate:true}, {becomePrivate:true}]) {
    const h = await harness(options);
    assert.ok(h.snapshots.every(s => s.tabs.every(t => !t.pageContext)));
  }
});
test('a stalled page does not block inventory sync', async () => {
  const h = await harness({slow:true});
  assert.ok(h.snapshots.length >= 2, h.debug); assert.equal(h.snapshots.at(-1).tabs[0].pageContext, undefined);
});
test('extractor reads bounded visible labels and ignores forms, editable and hidden regions', () => {
  const el = (text, flags = {}) => ({
    innerText: text,
    closest: () => flags.sensitive ? {} : null,
    querySelector: () => flags.editableChild ? {} : null,
    getClientRects: () => flags.hidden ? [] : [{}],
    getAttribute: name => name === 'aria-label' ? flags.label || null : null,
    get value() { throw Error('must never read form values'); }
  });
  const headings = [el('Piano workstation'), el('secret draft', {sensitive:true}), el('hidden', {hidden:true}), el('editable', {editableChild:true})];
  const controls = [el('Play'), el('Play'), el('Secret input', {sensitive:true}), el('Record')];
  const context = vm.createContext({URL, location: {protocol:'https:', href:'https://example.org/chordbook'}, getComputedStyle: () => ({}),
    document: {contentType:'text/html',
      querySelector: selector => selector.includes('name="description"') ? {getAttribute: () => 'p'.repeat(1000)} : null,
      querySelectorAll: selector => selector.startsWith('h1') ? headings : controls}});
  vm.runInContext(contextSource, context);
  const page = vm.runInContext('MoonshinePageContext.collect()', context);
  assert.equal(page.summary.length, 400);
  assert.deepEqual(Array.from(page.headings), ['Piano workstation']);
  assert.deepEqual(Array.from(page.controls), ['Play', 'Record']);
  assert.equal(vm.runInContext('MoonshinePageContext.origin("https://user:secret@example.org/")', context), null);
});

test('same-origin srcdoc tool descriptions are included; third-party frames are excluded', () => {
  const nested = {
    URL: 'about:srcdoc', contentType: 'text/html',
    querySelector: selector => selector.includes('name="description"') ? {getAttribute: () => 'An endless piano arcade with held chords and inversions.'} : null,
    querySelectorAll: () => []
  };
  const foreign = {URL:'https://third-party.org/', contentType:'text/html', querySelector() { throw Error('must not read another origin'); }};
  const frame = doc => ({contentDocument: doc, closest: () => null, getClientRects: () => [{}]});
  const document = {contentType:'text/html', querySelector: () => null, querySelectorAll: selector => selector === 'iframe' ? [frame(nested), frame(foreign)] : []};
  const context = vm.createContext({URL, document, location:{protocol:'https:', href:'https://example.org/chordbook'}, getComputedStyle: () => ({})});
  vm.runInContext(contextSource, context);
  assert.match(vm.runInContext('MoonshinePageContext.collect().summary', context), /piano arcade/);
});

test('permission approval survives popup closure and enables only its pending origin', async () => {
  const callbacks = {}, writes = [];
  const event = name => ({addListener(fn) { (callbacks[name] ||= []).push(fn); }});
  const api = {
    storage: {local: {get: async () => ({pendingContextSite: {origin:'https://example.org/*', requestedAt:Date.now()}, contextSites:[]}), set: async value => writes.push(value)}, onChanged:event('storage')},
    tabs: {}, windows:{onFocusChanged:event('focus')}, runtime:{onMessage:event('message')}, alarms:{create(){}, onAlarm:event('alarm')},
    permissions:{contains: async () => true, onAdded:event('added'), onRemoved:event('removed')}
  };
  for (const name of ['onCreated','onUpdated','onRemoved','onMoved','onAttached','onDetached','onActivated']) api.tabs[name] = event(name);
  const context = vm.createContext({chrome:api, URL, clearTimeout(){}, setTimeout(){}});
  vm.runInContext(contextSource,context); vm.runInContext(backgroundSource,context);
  await callbacks.added[0]({origins:['https://unrelated.org/*']});
  assert.equal(writes.length,0);
  await callbacks.added[0]({origins:['https://example.org/*']});
  assert.deepEqual(Array.from(writes[0].contextSites), ['https://example.org/*']);
  assert.equal(writes[0].pendingContextSite, null);
});
