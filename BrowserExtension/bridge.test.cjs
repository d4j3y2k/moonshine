const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(__dirname + '/background.js', 'utf8');

async function harness({ privateTab = false, closed = false, moved = false, stale = false, expired = false, version = 1, failSecond = false, duplicate = false, blockFirst = false } = {}) {
  const updates = [], snapshots = [], timers = new Map();
  let timerID = 0, title = 'Same title', releaseFirst;
  const gate = new Promise(resolve => { releaseFirst = resolve; });
  const callbacks = new Map();
  const tick = async () => { for(let i=0;i<20;i++) await new Promise(r => setImmediate(r)); };
  let gets = 0;
  const event = name => ({ addListener(fn) {
    if (!callbacks.has(name)) callbacks.set(name, []);
    callbacks.get(name).push(fn);
  } });
  const api = {
    storage: { local: { get: async () => ({ token: 'a'.repeat(64), client: 'client' }), set: async () => {} },
               session: { get: async () => ({ session: 'session' }), set: async () => {} } },
    tabs: { query: async () => [{ id: 1, windowId: 3, incognito: privateTab, title, url: 'https://example.org' }],
      get: async id => { gets++; if(closed) throw Error('closed'); return { id, windowId: moved && gets > 1 ? 8 : 3, active: true, incognito: privateTab }; },
      update: async (id, options) => updates.push(['tab', id, options]) },
    windows: { update: async (id, options) => updates.push(['window', id, options]), onFocusChanged: event('focus') },
    runtime: { onMessage: event('message') }, alarms: { create() {}, onAlarm: event('alarm') }
  };
  for(const e of ['onCreated','onUpdated','onRemoved','onMoved','onAttached','onDetached','onActivated']) api.tabs[e] = event(e);
  const context = vm.createContext({ chrome: api, navigator: {userAgent: 'Safari'}, crypto: require('node:crypto').webcrypto,
    clearTimeout: id => timers.delete(id), setTimeout: (fn, ms) => { timers.set(++timerID, {fn, ms}); return timerID; }, AbortSignal, fetch: async (_, request) => {
      snapshots.push(JSON.parse(request.body));
      if (blockFirst && snapshots.length === 1) await gate;
      if (failSecond && snapshots.length === 2) throw Error('offline');
      const commands = snapshots.length === 1 || duplicate ? [{ id: 'command', session: stale ? 'old' : 'session', tabID: 1, expiresAt: expired ? 0 : Date.now() + 4000 }] : [];
      return { ok: true, json: async () => version === 2 ? {commands, transportVersion:2} : commands };
    } });
  vm.runInContext(source, context);
  for(let i=0;i<20;i++) await new Promise(r => setImmediate(r));
  return { updates, snapshots, timers, context, releaseFirst, tick,
    setTitle(value) { title = value; },
    emit(name, ...args) { for (const callback of callbacks.get(name) || []) callback(...args); },
    async next() {
    const [id, timer] = timers.entries().next().value;
    timers.delete(id); timer.fn();
    for(let i=0;i<20;i++) await new Promise(r => setImmediate(r));
    return timer.ms;
  } };
}
test('private tabs never enter inventory or activation', async () => {
  const r = await harness({privateTab: true}); assert.equal(r.snapshots[0].tabs.length, 0); assert.equal(r.updates.length, 0);
});
test('closed ID cannot activate an index replacement', async () => assert.equal((await harness({closed: true})).updates.length, 0));
test('tab moved between lookup and activation uses its new window', async () => {
  const r = await harness({moved: true}); assert.equal(r.updates[0][1], 1); assert.equal(r.updates[1][1], 8);
});
test('old browser session command cannot activate reused tab IDs', async () => assert.equal((await harness({stale: true})).updates.length, 0));
test('expired command cannot activate after the UI has timed out', async () => assert.equal((await harness({expired: true})).updates.length, 0));

test('acknowledgement is flushed immediately, without waiting for the heartbeat', async () => {
  const h = await harness();
  assert.equal(await h.next(), 0);
  assert.deepEqual(h.snapshots[1].acknowledgements, [{id:'command', success:true}]);
  assert.equal(h.snapshots[0].transportVersion, 2);
});
test('v2 reconnects immediately; legacy idle sync waits one second', async () => {
  const modern = await harness({version:2});
  await modern.next();
  assert.equal([...modern.timers.values()][0].ms, 0);
  const legacy = await harness();
  await legacy.next();
  assert.equal([...legacy.timers.values()][0].ms, 1000);
});
test('failed ack delivery is retained and retried with offline backoff', async () => {
  const h = await harness({failSecond:true});
  await h.next();
  assert.equal(await h.next(), 1000);
  assert.deepEqual(h.snapshots[2].acknowledgements, [{id:'command',success:true}]);
});
test('replayed command is acknowledged without repeating activation', async () => {
  const h = await harness({duplicate:true});
  await h.next();
  assert.equal(h.updates.length, 2);
  assert.equal(await h.next(), 0);
  assert.deepEqual(h.snapshots[2].acknowledgements, [{id:'command',success:true}]);
});
test('events arriving during a busy sync are coalesced into the next sync', async () => {
  const h = await harness({stale:true, blockFirst:true});
  h.setTitle('Updated while HTTP request was in flight');
  h.emit('onUpdated', 1, {title:'Changed'});
  h.emit('focus', 3);
  await h.tick();
  assert.equal(h.snapshots.length, 1, 'No overlapping sync requests');
  h.releaseFirst(); await h.tick();
  assert.equal(await h.next(), 0, 'Busy events must flush without waiting for a heartbeat');
  assert.equal(h.snapshots.length, 2);
  assert.equal(h.snapshots[1].tabs[0].title, 'Updated while HTTP request was in flight');
});
