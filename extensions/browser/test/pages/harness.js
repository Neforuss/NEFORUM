// Stands in for the extension's background script on the test pages, so the
// real content scripts (../../src/content/*.js) run in an ordinary tab.
//   ?p=<platformId>  the job's platform (default: generic)
//   ?qp=0            the job does not allow posting from the page
//   ?pref=0          NEFORUM opened the page in another browser
// Results the content script reports land in window.__results.
(() => {
  const q = new URLSearchParams(location.search);
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
    text: 'Hello from NEFORUM #test',
    title: null,
    snippets: [],
    media: [{ index: 0, name: 'card.png', mimeType: 'image/png', size: atob(png).length, kind: 'image' }],
    steps: '',
    quickPost: q.get('qp') !== '0',
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
