// Stands in for the extension's background script on the test pages, so the
// real content scripts (../../src/content/*.js) run in an ordinary tab.
//   ?p=<platformId>  the job's platform (default: generic)
//   ?qp=0            the job does not allow posting from the page
//   ?pref=0          NEFORUM opened the page in another browser
//   ?auto=1          the job is automatic (the user turned on automatic
//                    posting): filled in, a 3-second countdown, then Post
// A page can set window.NEFORUM_TEST_PARTS (a thread's parts),
// NEFORUM_TEST_TAGS, NEFORUM_TEST_TITLE, NEFORUM_TEST_DESCRIPTION and
// NEFORUM_TEST_ARTWORK before loading this (?rating=adult overrides the
// artwork's rating).
// Results the content script reports land in window.__results.
(() => {
  const q = new URLSearchParams(location.search);
  const artwork = window.NEFORUM_TEST_ARTWORK && { ...window.NEFORUM_TEST_ARTWORK, ...(q.get('rating') ? { maturity: q.get('rating') } : {}) };
  const canvas = Object.assign(document.createElement('canvas'), { width: 64, height: 64 });
  const g = canvas.getContext('2d');
  g.fillStyle = '#7D00FF';
  g.fillRect(0, 0, 64, 64);
  const png = canvas.toDataURL('image/png').split(',')[1];
  const job = {
    id: `j_test_${q.get('p') ?? 'generic'}`,
    platformId: q.get('p') ?? 'generic',
    platformName: 'Test site',
    url: location.href,
    hosts: [location.host],
    // A page can set its own text, or no photo, before loading this.
    text: window.NEFORUM_TEST_TEXT ?? 'Hello from NEFORUM #test',
    title: window.NEFORUM_TEST_TITLE ?? null,
    ...(window.NEFORUM_TEST_DESCRIPTION ? { description: window.NEFORUM_TEST_DESCRIPTION } : {}),
    ...(artwork ? { artwork } : {}),
    snippets: window.NEFORUM_TEST_SNIPPETS ?? [],
    media: window.NEFORUM_TEST_MEDIA === false ? [] : [{ index: 0, name: 'card.png', mimeType: 'image/png', size: atob(png).length, kind: 'image' }],
    steps: '',
    quickPost: q.get('qp') !== '0',
    autoPost: q.get('auto') === '1',
    ...(window.NEFORUM_TEST_PARTS ? { parts: window.NEFORUM_TEST_PARTS } : {}),
    ...(window.NEFORUM_TEST_TAGS ? { tags: window.NEFORUM_TEST_TAGS } : {}),
    preferred: q.get('pref') !== '0',
    createdAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 600000).toISOString(),
  };
  window.__results = [];
  globalThis.browser = {
    runtime: {
      async sendMessage(msg) {
        if (msg.type === 'job') return { ok: true, value: { job } };
        if (msg.type === 'result') {
          window.__results.push(msg.result);
          return { ok: true, value: { ok: true } };
        }
        return { ok: false, error: `unknown ${msg.type}` };
      },
      connect() {
        const listeners = [];
        return {
          postMessage: ({ index }) =>
            setTimeout(() => listeners.forEach((f) => f({ index, type: 'image/png', size: atob(png).length, data: png, done: true })), 30),
          onMessage: { addListener: (f) => listeners.push(f) },
          onDisconnect: { addListener() {} },
          disconnect() {},
        };
      },
      onMessage: { addListener() {} },
    },
  };
})();
