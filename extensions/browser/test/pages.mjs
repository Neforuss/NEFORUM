// Runs the real content scripts on the test pages in a headless Chrome or
// Edge, with real (trusted) mouse clicks, and checks what happened:
//   node extensions/browser/test/pages.mjs [browser.exe]
// The pages get a stand-in background (pages/harness.js); this script serves
// this folder itself on a free port and drives the browser over the DevTools
// protocol (no dependencies). The panel's buttons are in a closed shadow
// root, which the protocol reaches (the page's own scripts cannot).
// Exits 1 on any failure. Scenarios (NEFORUM 1.4.1):
//   - YouTube Posts: Attach puts the photo into the post box through its
//     Image button, opens no file window, leaves the search bar alone;
//   - the user's own click on a site's Post is watched and reported
//     (posted: confirmed), the decoy Post is never pressed;
//   - I posted it reports posted: user;
//   - a text-only YouTube Posts job puts the words in and no file anywhere.
import { createServer } from 'node:http';
import { readFileSync, existsSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.png': 'image/png' };

function browserPath() {
  const given = process.argv[2];
  const candidates = [
    given,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean);
  const found = candidates.find((c) => existsSync(c));
  if (!found) throw new Error('No Chrome or Edge found: pass its path.');
  return found;
}

function serve() {
  const server = createServer((req, res) => {
    const file = path.normalize(path.join(ROOT, decodeURIComponent(req.url.split('?')[0])));
    if (!file.startsWith(ROOT) || !existsSync(file) || statSync(file).isDirectory()) {
      res.writeHead(404);
      return res.end();
    }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(readFileSync(file));
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function launch(exe) {
  const profile = mkdtempSync(path.join(tmpdir(), 'neforum-pages-'));
  const proc = spawn(exe, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--window-size=1280,900', 'about:blank'], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  const ws = await new Promise((resolve, reject) => {
    let err = '';
    proc.stderr.on('data', (d) => {
      err += d;
      const m = /DevTools listening on (ws:\/\/\S+)/.exec(err);
      if (m) resolve(m[1]);
    });
    proc.on('exit', (code) => reject(new Error(`the browser exited (${code}): ${err.slice(0, 400)}`)));
    setTimeout(() => reject(new Error('the browser did not start')), 20000);
  });
  return { proc, profile, ws };
}

/** A DevTools protocol session on one page. */
async function connect(browserWs) {
  const base = new URL(browserWs);
  const list = await (await fetch(`http://${base.host}/json/list`)).json();
  const page = list.find((t) => t.type === 'page');
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => {
    socket.onopen = r;
    socket.onerror = j;
  });
  let id = 0;
  const waiting = new Map();
  socket.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && waiting.has(m.id)) {
      const { resolve, reject } = waiting.get(m.id);
      waiting.delete(m.id);
      if (m.error) reject(new Error(m.error.message));
      else resolve(m.result);
    }
  };
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      waiting.set(++id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
  return { send, close: () => socket.close() };
}

async function evaluate(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(`${expression}: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
  return r.result.value;
}

async function until(cdp, expression, what, timeout = 15000) {
  const end = Date.now() + timeout;
  for (;;) {
    if (await evaluate(cdp, expression)) return;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

async function clickAt(cdp, x, y) {
  for (const type of ['mousePressed', 'mouseReleased']) {
    await cdp.send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
  }
}

/** A real click on the page's element [selector]. */
async function clickSelector(cdp, selector) {
  const r = await evaluate(cdp, `(() => { const e = document.querySelector(${JSON.stringify(selector)}); e.scrollIntoView({ block: 'center' }); const b = e.getBoundingClientRect(); return [b.left + b.width / 2, b.top + b.height / 2]; })()`);
  await clickAt(cdp, r[0], r[1]);
}

/** A real click on the NEFORUM panel's button that says [text] (inside its closed shadow root). */
async function clickPanel(cdp, text) {
  const { root } = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
  let found = null;
  const textOf = (n) => (n.nodeType === 3 ? n.nodeValue : (n.children ?? []).map(textOf).join('')) + (n.shadowRoots ?? []).map(textOf).join('');
  const walk = (n, inPanel) => {
    if (found) return;
    const here = inPanel || (n.attributes ?? []).join(' ').includes('neforum-ext-panel');
    if (here && n.nodeName === 'BUTTON' && textOf(n).trim().startsWith(text)) found = n;
    for (const c of [...(n.children ?? []), ...(n.shadowRoots ?? [])]) walk(c, here);
  };
  walk(root, false);
  if (!found) throw new Error(`no panel button "${text}"`);
  const { model } = await cdp.send('DOM.getBoxModel', { nodeId: found.nodeId });
  const q = model.content;
  await clickAt(cdp, (q[0] + q[4]) / 2, (q[1] + q[5]) / 2);
}

async function open(cdp, url) {
  // Each scenario starts afresh: the tab remembers jobs it filled in
  // (sessionStorage), and the test jobs' ids repeat between scenarios.
  await evaluate(cdp, 'try { sessionStorage.clear() } catch {}');
  await cdp.send('Page.navigate', { url });
  await until(cdp, `document.readyState === 'complete' && Array.isArray(window.__results)`, `${url} to load`);
}

const scenarios = {
  async 'YouTube Posts: Attach goes through the Image button into the post box, not the search bar'(cdp, base) {
    await open(cdp, `${base}/test/pages/youtube_image.html?p=youtube_posts&qp=0`);
    await until(cdp, 'window.__results.length >= 1', 'the fill report');
    let r = await evaluate(cdp, 'window.result()');
    assert.deepEqual(r.added, ['card.png'], 'the fill put the photo into the post box');
    assert.equal(r.windows, 0, 'no file window opened during the fill');
    await clickPanel(cdp, 'Attach file');
    await until(cdp, 'window.result().added.length === 2', 'the photo from Attach');
    r = await evaluate(cdp, 'window.result()');
    assert.equal(r.windows, 0, 'Attach opened no file window');
    assert.equal(r.search, '', 'nothing went into the search bar');
    assert.equal(r.searchFocused, false, 'the search bar was not focused');
  },

  async 'YouTube Posts, text only (1.4.1): the words go in, no file and no image option'(cdp, base) {
    await open(cdp, `${base}/test/pages/youtube_image.html?p=youtube_posts&qp=0&media=0`);
    await until(cdp, 'window.__results.length >= 1', 'the fill report');
    const r = await evaluate(cdp, 'window.result()');
    assert.equal(r.text, 'A photo for the channel', 'the words are in the post box');
    assert.deepEqual(r.added, [], 'no file was added');
    assert.equal(r.inputs, 0, 'the image option was never opened');
    assert.equal(r.windows, 0);
    assert.equal(r.search, '');
  },
  async "the user's own Post press is watched and reported as confirmed"(cdp, base) {
    await open(cdp, `${base}/test/pages/post.html?qp=0`);
    await until(cdp, 'window.__results.length >= 1', 'the fill report');
    await until(cdp, '!document.getElementById("post").disabled', 'the "upload"', 8000);
    await clickSelector(cdp, '#post');
    await until(cdp, 'window.__results.some((r) => r.posted)', 'the posted report');
    const posted = await evaluate(cdp, 'window.__results.filter((r) => r.posted).map((r) => r.posted)');
    assert.deepEqual(posted, ['confirmed']);
    assert.equal(await evaluate(cdp, 'window.postClicks'), 1, 'the user pressed Post once; the extension pressed nothing');
    assert.equal(await evaluate(cdp, 'window.untrustedClicks'), 0);
    assert.equal(await evaluate(cdp, 'window.decoyClicks'), 0);
  },

  async 'I posted it reports posted: user'(cdp, base) {
    await open(cdp, `${base}/test/pages/post.html?qp=0&p=tiktok`);
    await until(cdp, 'window.__results.length >= 1', 'the fill report');
    await clickPanel(cdp, 'I posted it');
    await until(cdp, 'window.__results.some((r) => r.posted)', 'the posted report');
    assert.deepEqual(await evaluate(cdp, 'window.__results.filter((r) => r.posted).map((r) => r.posted)'), ['user']);
    assert.equal(await evaluate(cdp, 'window.postClicks + window.decoyClicks'), 0, 'nothing was pressed on the page');
  },
};

const server = await serve();
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch(browserPath());
let failed = 0;
try {
  const cdp = await connect(browser.ws);
  await cdp.send('Page.enable');
  await cdp.send('DOM.enable');
  for (const [name, run] of Object.entries(scenarios)) {
    try {
      await run(cdp, base);
      console.log(`ok - ${name}`);
    } catch (e) {
      failed++;
      console.log(`not ok - ${name}\n  ${e.message}`);
    }
  }
  cdp.close();
} finally {
  browser.proc.kill();
  server.close();
  await sleep(300);
  try {
    rmSync(browser.profile, { recursive: true, force: true });
  } catch {
    // The browser may still hold its profile for a moment.
  }
}
console.log(failed ? `${failed} failed` : 'all passed');
process.exit(failed ? 1 : 0);
