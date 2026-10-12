// End-to-end check against the REAL NEFORUM app server (started by
// apps/neforum_app/test/browser_extension_e2e_test.dart):
//   node extensions/browser/test/e2e.mjs <pairing code> <expected host>
// Prints one JSON line with what happened; exits 1 on any failure.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const [code, host] = process.argv.slice(2);
const store = {};
const listeners = {};
const chrome = {
  storage: { local: { get: async (k) => (k in store ? { [k]: store[k] } : {}), set: async (o) => Object.assign(store, o), remove: async (k) => delete store[k] } },
  runtime: { onMessage: { addListener: (f) => (listeners.message = f) }, onConnect: { addListener: (f) => (listeners.connect = f) } },
};
const sandbox = { chrome, fetch, AbortSignal, URL, navigator: { userAgent: 'Mozilla/5.0 Firefox/140.0' }, btoa, atob, module: { exports: {} }, console };
vm.runInNewContext(readFileSync(new URL('../src/background.js', import.meta.url), 'utf8'), sandbox);
const send = (msg) => new Promise((resolve) => listeners.message(msg, {}, resolve));
const out = {};
try {
  out.status1 = (await send({ type: 'status' })).value;
  const pair = await send({ type: 'pair', code });
  if (!pair.ok) throw new Error(`pair: ${pair.error}`);
  out.status2 = (await send({ type: 'status' })).value;
  const job = (await send({ type: 'job', host })).value.job;
  if (!job) throw new Error('no job for host');
  out.job = { id: job.id, platformId: job.platformId, text: job.text, media: job.media };
  out.otherHost = (await send({ type: 'job', host: 'example.invalid' })).value.job;
  // Media through the chunked port.
  const chunks = [];
  await new Promise((resolve, reject) => {
    const port = {
      name: 'neforum-media',
      postMessage: (m) => {
        if (m.error) reject(new Error(m.error));
        chunks.push(m);
        if (m.done) resolve();
      },
      onMessage: { addListener: (f) => (port.handler = f) },
    };
    listeners.connect(port);
    port.handler({ jobId: job.id, index: 0 });
  });
  const bytes = Buffer.concat(chunks.map((c) => Buffer.from(c.data, 'base64')));
  out.mediaBytes = bytes.length;
  out.mediaType = chunks[0].type;
  out.mediaFirst = bytes[0];
  out.mediaLast = bytes[bytes.length - 1];
  const result = await send({ type: 'result', jobId: job.id, result: { status: 'filled', text: true, media: 1, message: 'e2e' } });
  if (!result.ok) throw new Error(`result: ${result.error}`);
  const unpair = await send({ type: 'unpair' });
  out.unpaired = unpair.ok && !store.token;
  out.status3 = (await send({ type: 'status' })).value;
  console.log(JSON.stringify(out));
} catch (e) {
  console.log(JSON.stringify({ ...out, error: e.message }));
  process.exit(1);
}
