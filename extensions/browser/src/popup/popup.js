// NEFORUM browser extension: the toolbar popup. Pairing, status, and "Fill
// in this page" for sites the content script is not registered on.

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

async function ask(type, extra = {}) {
  const r = await api.runtime.sendMessage({ type, ...extra });
  if (!r?.ok) throw new Error(r?.error ?? 'The extension did not answer.');
  return r.value;
}

function setStatus(text, tone = '') {
  $('status').textContent = text;
  $('status').className = `status ${tone}`;
}

/** The sites the content script is registered on, plus the app's address. */
function wantedOrigins() {
  const m = api.runtime.getManifest();
  const origins = new Set(m.host_permissions ?? []);
  for (const cs of m.content_scripts ?? []) for (const o of cs.matches ?? []) origins.add(o);
  return [...origins];
}

async function refresh() {
  for (const id of ['pair', 'ready', 'access', 'unpair']) $(id).hidden = true;
  let s;
  try {
    s = await ask('status');
  } catch (e) {
    setStatus(e.message, 'err');
    return;
  }
  // Firefox grants host access only when the user allows it.
  const granted = await api.permissions.contains({ origins: wantedOrigins() }).catch(() => true);
  $('access').hidden = granted;

  if (!s.app) {
    setStatus('NEFORUM is not running on this computer. Start it, then open this again.', 'warn');
    return;
  }
  if (!s.paired) {
    setStatus(s.hasToken ? 'NEFORUM no longer knows this browser. Pair it again.' : `Found NEFORUM ${s.version ?? ''}. Pair this browser once.`, 'warn');
    $('pair').hidden = false;
    $('code').focus();
    return;
  }
  setStatus(`Paired with NEFORUM ${s.version ?? ''}.`, 'ok');
  $('ready').hidden = false;
  $('unpair').hidden = false;
}

$('pair-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  setStatus('Pairing…');
  try {
    await ask('pair', { code: $('code').value });
    $('code').value = '';
    await refresh();
  } catch (err) {
    setStatus(err.message, 'err');
  }
});

$('fill').addEventListener('click', async () => {
  setStatus('Filling in this page…');
  try {
    await ask('fillTab');
    window.close();
  } catch (err) {
    setStatus(err.message, 'warn');
  }
});

$('grant').addEventListener('click', () => {
  // permissions.request must run straight from the click, before any await.
  api.permissions.request({ origins: wantedOrigins() }).then(refresh, (err) => setStatus(err.message, 'err'));
});

$('unpair').addEventListener('click', async () => {
  await ask('unpair').catch(() => {});
  await refresh();
});

refresh();
