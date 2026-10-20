// NEFORUM browser extension: background script (Chrome service worker,
// Firefox event page). The only part that talks to the NEFORUM app, over
// http://127.0.0.1 (see ../PROTOCOL.md). Content scripts and the popup ask
// it for things by message.

const api = globalThis.browser ?? globalThis.chrome;

/**
 * Ports the app may listen on, in the order it tries them (kBrowserBridgePorts
 * in the app). The 4177x ports are for when Windows has reserved the 5277x
 * ones (Hyper-V reserves blocks of ports from 49152 up). Tests set
 * NEFORUM_PORTS in their sandbox, so they don't meet a NEFORUM that is
 * running on this computer.
 */
const PORTS = globalThis.NEFORUM_PORTS ?? [
  52772, 52773, 52774, 52775, 52776, 52777, 52778, 52779,
  41772, 41773, 41774, 41775, 41776, 41777, 41778, 41779,
];

/** Raw bytes per media chunk sent to a content script (base64 makes it ~1 MB). */
const CHUNK = 768 * 1024;

class BridgeError extends Error {
  constructor(code, message) {
    super(message ?? code);
    this.code = code;
  }
}

/** Base URL of the app once found, e.g. http://127.0.0.1:52772. */
let base = null;

async function getToken() {
  const { token } = await api.storage.local.get('token');
  return typeof token === 'string' && token ? token : null;
}

function authHeaders(token) {
  return token ? { Authorization: `Bearer ${token}` } : {};
}

/** Finds the app on its ports. Returns the hello body or null. */
async function findApp(token) {
  const order = base ? [Number(new URL(base).port), ...PORTS.filter((p) => `${p}` !== new URL(base).port)] : PORTS;
  for (const port of order) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/v1/hello`, {
        headers: authHeaders(token),
        signal: AbortSignal.timeout(900),
        cache: 'no-store',
      });
      if (!r.ok) continue;
      const hello = await r.json();
      if (hello && hello.app === 'NEFORUM') {
        base = `http://127.0.0.1:${port}`;
        return hello;
      }
    } catch {
      // Nothing on this port (or not NEFORUM): try the next one.
    }
  }
  base = null;
  return null;
}

/** Calls the app with the stored token; finds it again if it moved. */
async function call(path, { method = 'GET', body } = {}) {
  const token = await getToken();
  if (!token) throw new BridgeError('not-paired', 'Pair this browser with NEFORUM first.');
  const send = () =>
    fetch(base + path, {
      method,
      headers: { ...authHeaders(token), ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store',
    });
  if (!base && !(await findApp(token))) throw new BridgeError('no-app', 'NEFORUM is not running on this computer.');
  let r;
  try {
    r = await send();
  } catch {
    if (!(await findApp(token))) throw new BridgeError('no-app', 'NEFORUM is not running on this computer.');
    r = await send();
  }
  if (r.status === 401) {
    await api.storage.local.remove('token');
    throw new BridgeError('not-paired', 'NEFORUM no longer knows this browser. Pair it again.');
  }
  return r;
}

/**
 * What this browser is, as well as it can tell: Chromium browsers (Chrome,
 * Helium, Vivaldi...) share a user agent, but only Google Chrome lists the
 * "Google Chrome" brand. NEFORUM guesses the program from this, and the user
 * can correct it there ("Opens in").
 */
function browserName() {
  const ua = navigator.userAgent;
  const brands = (navigator.userAgentData?.brands ?? []).map((b) => b.brand);
  if (ua.includes('Firefox/')) return 'Firefox';
  if (brands.includes('Microsoft Edge') || ua.includes('Edg/')) return 'Microsoft Edge';
  if (brands.includes('Opera') || ua.includes('OPR/')) return 'Opera';
  if (brands.includes('Brave') || navigator.brave) return 'Brave';
  if (brands.length && !brands.includes('Google Chrome')) return 'Chromium-based browser';
  return 'Chrome';
}

// ---- requests from the popup and content scripts ----------------------------

const handlers = {
  async status() {
    const token = await getToken();
    const hello = await findApp(token);
    return { app: !!hello, paired: !!(hello && hello.paired), version: hello?.version ?? null, hasToken: !!token };
  },

  async pair({ code }) {
    const digits = String(code ?? '').replace(/\D/g, '');
    if (digits.length !== 6) throw new BridgeError('bad-code', 'The pairing code has 6 digits.');
    if (!base && !(await findApp(null))) throw new BridgeError('no-app', 'NEFORUM is not running on this computer.');
    const r = await fetch(`${base}/v1/pair`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: digits, browser: browserName() }),
      cache: 'no-store',
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || typeof j.token !== 'string') throw new BridgeError('pair-refused', j.error ?? `NEFORUM said no (HTTP ${r.status}).`);
    await api.storage.local.set({ token: j.token });
    return { paired: true };
  },

  async unpair() {
    try {
      await call('/v1/unpair', { method: 'POST' });
    } catch {
      // Forget the token here even when the app is not running.
    }
    await api.storage.local.remove('token');
    return { paired: false };
  },

  async job({ host }) {
    if (!(await getToken())) return { job: null, reason: 'not-paired' };
    const r = await call(`/v1/job?host=${encodeURIComponent(host)}`);
    if (r.status === 204) return { job: null };
    if (!r.ok) throw new BridgeError('job-failed', `NEFORUM answered HTTP ${r.status}.`);
    return { job: await r.json() };
  },

  async result({ jobId, result }) {
    await call(`/v1/job/${encodeURIComponent(jobId)}/result`, { method: 'POST', body: result });
    return { ok: true };
  },

  /** Popup: run the filler in the current tab (any site, via activeTab). */
  async fillTab() {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id || !/^https?:/.test(tab.url ?? '')) throw new BridgeError('no-tab', 'Open the platform\'s page in this tab first.');
    const { job } = await handlers.job({ host: new URL(tab.url).host });
    if (!job) throw new BridgeError('no-job', 'Nothing is waiting for this site. In NEFORUM, open the post\'s hand-off and click Open.');
    // Mark the injection as manual so the scripts wait for fillNow instead
    // of filling in on their own as well.
    await api.scripting.executeScript({ target: { tabId: tab.id }, func: () => { (globalThis.NEFORUM_EXT ??= {}).manual = true; } });
    await api.scripting.executeScript({
      target: { tabId: tab.id },
      files: ['content/fill.js', 'content/recipes.js', 'content/panel.js', 'content/main.js'],
    });
    await api.tabs.sendMessage(tab.id, { type: 'fillNow' });
    return { ok: true };
  },
};

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const handler = msg && handlers[msg.type];
  if (!handler) return false;
  handler(msg, sender).then(
    (value) => sendResponse({ ok: true, value }),
    (e) => sendResponse({ ok: false, code: e.code ?? 'error', error: e.message ?? String(e) }),
  );
  return true; // answer asynchronously (Chrome needs this; Firefox accepts it)
});

// ---- media, streamed to the content script in chunks -------------------------

function toBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

api.runtime.onConnect.addListener((port) => {
  if (port.name !== 'neforum-media') return;
  port.onMessage.addListener(async ({ jobId, index }) => {
    try {
      const r = await call(`/v1/job/${encodeURIComponent(jobId)}/media/${Number(index)}`);
      if (!r.ok) throw new BridgeError('media-failed', `NEFORUM answered HTTP ${r.status} for file ${index + 1}.`);
      const bytes = new Uint8Array(await r.arrayBuffer());
      const type = r.headers.get('Content-Type') ?? 'application/octet-stream';
      for (let at = 0; at < bytes.length || at === 0; at += CHUNK) {
        const done = at + CHUNK >= bytes.length;
        port.postMessage({ index, type, size: bytes.length, data: toBase64(bytes.subarray(at, at + CHUNK)), done });
        if (done) break;
      }
    } catch (e) {
      port.postMessage({ index, error: e.message ?? String(e) });
    }
  });
});

// For tests in Node (no effect in the browser).
if (typeof module !== 'undefined') module.exports = { handlers, findApp, toBase64, browserName, BridgeError, PORTS };
