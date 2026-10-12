// Tests the extension's background script against a stand-in NEFORUM app
// that follows ../PROTOCOL.md.   node --test extensions/browser/test
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Ports of their own (not 52772-52779), so a NEFORUM running on this computer is not in the way.
// The stand-in listens on the last one, so discovery walks the list.
const PORTS = [52790, 52791, 52792];
const PORT = PORTS.at(-1);
const TOKEN = 'tok_0123456789abcdefghijklmnopqrstuvwxyzABCD';
const media = Buffer.alloc(2 * 1024 * 1024 + 123, 7); // > 2 chunks
media[0] = 1;
media[media.length - 1] = 9;
const state = { results: [], tokenValid: true, job: true };

function job() {
  return {
    id: 'j_1',
    platformId: 'youtube_posts',
    platformName: 'YouTube Posts',
    url: 'https://www.youtube.com/@examplechannel/posts',
    hosts: ['www.youtube.com', 'youtube.com'],
    text: 'Hello',
    title: null,
    snippets: [],
    media: [{ index: 0, name: 'a.jpg', mimeType: 'image/jpeg', size: media.length, kind: 'image' }],
    steps: '1. Paste.',
    createdAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 600000).toISOString(),
  };
}

const server = http.createServer((req, res) => {
  const authed = state.tokenValid && req.headers.authorization === `Bearer ${TOKEN}`;
  const send = (status, body, type = 'application/json') => {
    res.writeHead(status, { 'Content-Type': type });
    res.end(body === undefined ? undefined : type === 'application/json' ? JSON.stringify(body) : body);
  };
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  if (url.pathname === '/v1/hello') return send(200, { app: 'NEFORUM', version: '1.0.0', protocol: 1, paired: authed });
  if (url.pathname === '/v1/pair') {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const { code, browser } = JSON.parse(body);
      if (code === '123456' && browser) send(200, { token: TOKEN });
      else send(403, { error: 'That code is wrong or has expired. Make a new one in NEFORUM.' });
    });
    return;
  }
  if (!authed) return send(401, { error: 'Pair again' });
  if (url.pathname === '/v1/job') {
    return state.job && url.searchParams.get('host') === 'www.youtube.com' ? send(200, job()) : send(204);
  }
  if (url.pathname === '/v1/job/j_1/media/0') return send(200, media, 'image/jpeg');
  if (url.pathname === '/v1/job/j_1/result') {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      state.results.push(JSON.parse(body));
      send(204);
    });
    return;
  }
  send(404, { error: 'nope' });
});

/** Loads background.js in a sandbox with a fake extension API. */
function loadBackground() {
  const store = {};
  const listeners = { message: null, connect: null };
  const chrome = {
    storage: {
      local: {
        get: async (k) => (k in store ? { [k]: store[k] } : {}),
        set: async (o) => Object.assign(store, o),
        remove: async (k) => delete store[k],
      },
    },
    runtime: {
      onMessage: { addListener: (f) => (listeners.message = f) },
      onConnect: { addListener: (f) => (listeners.connect = f) },
    },
  };
  const sandbox = { chrome, fetch, AbortSignal, URL, navigator: { userAgent: 'Mozilla/5.0 Chrome/141.0' }, btoa, atob, module: { exports: {} }, console, NEFORUM_PORTS: PORTS };
  vm.runInNewContext(readFileSync(new URL('../src/background.js', import.meta.url), 'utf8'), sandbox);
  const send = (msg) => new Promise((resolve) => listeners.message(msg, {}, resolve));
  return { store, send, listeners };
}

before(() => new Promise((r) => server.listen(PORT, '127.0.0.1', r)));
after(() => new Promise((r) => server.close(r)));

test('pairing, status, job, media in chunks, result, and a revoked token', async () => {
  const bg = loadBackground();

  let r = await bg.send({ type: 'status' });
  assert.equal(r.ok, true);
  assert.deepEqual({ app: r.value.app, paired: r.value.paired }, { app: true, paired: false }, 'found the app on the last port');

  r = await bg.send({ type: 'job', host: 'www.youtube.com' });
  assert.equal(r.value.job, null, 'no token, no job');

  r = await bg.send({ type: 'pair', code: '000000' });
  assert.equal(r.ok, false);
  assert.match(r.error, /wrong or has expired/);
  r = await bg.send({ type: 'pair', code: '12 34 56' });
  assert.equal(r.ok, true);
  assert.equal(bg.store.token, TOKEN);

  r = await bg.send({ type: 'status' });
  assert.equal(r.value.paired, true);

  r = await bg.send({ type: 'job', host: 'www.youtube.com' });
  assert.equal(r.value.job.id, 'j_1');
  r = await bg.send({ type: 'job', host: 'x.com' });
  assert.equal(r.value.job, null, '204 means nothing for this site');

  // Media: the content script's port receives base64 chunks.
  const received = [];
  const port = {
    name: 'neforum-media',
    postMessage: (m) => received.push(m),
    onMessage: { addListener: (f) => (port.handler = f) },
  };
  bg.listeners.connect(port);
  await port.handler({ jobId: 'j_1', index: 0 });
  assert.ok(received.length >= 3, `streamed in chunks (${received.length})`);
  assert.equal(received.at(-1).done, true);
  const bytes = Buffer.concat(received.map((m) => Buffer.from(m.data, 'base64')));
  assert.equal(bytes.length, media.length);
  assert.ok(bytes.equals(media), 'bytes arrive unchanged');
  assert.equal(received[0].type, 'image/jpeg');

  r = await bg.send({ type: 'result', jobId: 'j_1', result: { status: 'filled', text: true, media: 1, message: '' } });
  assert.equal(r.ok, true);
  assert.deepEqual(state.results.at(-1), { status: 'filled', text: true, media: 1, message: '' });

  // The app forgot this browser: the token goes, and the user is told to pair again.
  state.tokenValid = false;
  r = await bg.send({ type: 'job', host: 'www.youtube.com' });
  assert.equal(r.ok, false);
  assert.equal(r.code, 'not-paired');
  assert.equal(bg.store.token, undefined);
});

test('browser name: only Google Chrome says Chrome; other Chromium browsers say so', () => {
  const nameFor = (navigator) => {
    const sandbox = { module: { exports: {} }, chrome: { storage: { local: {} }, runtime: { onMessage: { addListener() {} }, onConnect: { addListener() {} } } }, btoa, navigator };
    vm.runInNewContext(readFileSync(new URL('../src/background.js', import.meta.url), 'utf8'), sandbox);
    return sandbox.module.exports.browserName();
  };
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
  const brands = (...names) => ({ brands: names.map((brand) => ({ brand, version: '141' })) });
  assert.equal(nameFor({ userAgent: ua, userAgentData: brands('Google Chrome', 'Chromium', 'Not.A/Brand') }), 'Chrome');
  assert.equal(nameFor({ userAgent: ua, userAgentData: brands('Chromium', 'Not.A/Brand') }), 'Chromium-based browser', 'Helium, Vivaldi...');
  assert.equal(nameFor({ userAgent: `${ua} Edg/141.0`, userAgentData: brands('Microsoft Edge', 'Chromium') }), 'Microsoft Edge');
  assert.equal(nameFor({ userAgent: ua, userAgentData: brands('Brave', 'Chromium') }), 'Brave');
  assert.equal(nameFor({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; rv:140.0) Gecko/20100101 Firefox/140.0' }), 'Firefox');
  assert.equal(nameFor({ userAgent: ua }), 'Chrome', 'no brands to go on');
});

test('the base64 helper matches Node', () => {
  const bg = loadBackground();
  void bg;
  const sandbox = { module: { exports: {} }, chrome: { storage: { local: {} }, runtime: { onMessage: { addListener() {} }, onConnect: { addListener() {} } } }, btoa, navigator: { userAgent: '' } };
  vm.runInNewContext(readFileSync(new URL('../src/background.js', import.meta.url), 'utf8'), sandbox);
  const data = new Uint8Array(70000).map((_, i) => (i * 31) % 256);
  assert.equal(sandbox.module.exports.toBase64(data), Buffer.from(data).toString('base64'));
});
