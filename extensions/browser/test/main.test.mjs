// Drives the content script's main.js without a page: the recipe, the panel
// and the page helpers are stand-ins, and a stand-in NEFORUM answers the
// background script's messages. Checks when the extension presses Post by
// itself and what it tells NEFORUM.
//   node --test extensions/browser/test/main.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const SOURCE = readFileSync(new URL('../src/content/main.js', import.meta.url), 'utf8');

/** A stand-in NEFORUM: [job] is the job it serves (or a function of the request count and page id). */
function standInApp(job) {
  const state = { job, pages: [], reports: [], refuse: false };
  return {
    state,
    async job({ page }) {
      state.pages.push(page);
      return typeof state.job === 'function' ? state.job(state.pages.length, page) : state.job;
    },
    async result({ jobId, result }) {
      if (state.refuse) throw new Error('That hand-off has expired.');
      state.reports.push({ jobId, ...result });
    },
  };
}

/**
 * Loads main.js as "Fill in this page" injects it, on a stand-in page at
 * [href] whose tab keeps [session] (sessionStorage). [dialog]: a dialog the
 * site shows after Post, with a confirming button of its own; [onPress] runs
 * after each press. Returns what happened on the page (Post presses, text
 * insertions, the panel's lines) and the user's controls: the panel's
 * buttons and the keyboard.
 */
function loadPage({ app, recipe = {}, href = 'https://www.example.test/compose', session = new Map(), dialog = null, onPress = null }) {
  const pressed = [];
  const inserted = [];
  const statuses = [];
  const listeners = {};
  let onMessage = null;
  let actions = null;
  const editor = { isConnected: true };
  const button = { label: 'Post' };
  const panel = {
    set: (text) => statuses.push(text),
    done: ({ headline }) => statuses.push(headline),
    setPost() {},
    close() {},
  };
  const fill = {
    async waitFor(find) {
      for (let i = 0; i < 3; i++) {
        const found = find();
        if (found) return found;
        await Promise.resolve();
      }
      return null;
    },
    findEditor: () => editor,
    editableOf: () => null,
    async insertText(el, text, options = {}) {
      inserted.push({ el, text, options });
      return 'paste';
    },
    attachFiles: async () => 'input',
    setInputFiles: () => true,
    sleep: () => new Promise((r) => setImmediate(r)),
    enabled: () => true,
    findPostButton: ({ root }) => ({ button: dialog && root === dialog ? dialog.button : button, scope: { contains: () => true } }),
    waitPosted: async () => true,
    pressPost: (b) => {
      pressed.push(b);
      onPress?.(b);
    },
    visible: () => true,
  };
  const chrome = {
    runtime: {
      async sendMessage(msg) {
        try {
          if (msg.type === 'job') return { ok: true, value: { job: await app.job(msg) } };
          if (msg.type === 'result') {
            await app.result(msg);
            return { ok: true, value: { ok: true } };
          }
        } catch (e) {
          return { ok: false, code: 'result-refused', error: e.message };
        }
        return { ok: false, error: 'Unknown request.' };
      },
      onMessage: { addListener: (f) => (onMessage = f) },
    },
  };
  const url = new URL(href);
  const sandbox = {
    console,
    setTimeout,
    clearTimeout,
    setImmediate,
    crypto: {
      getRandomValues(bytes) {
        for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
        return bytes;
      },
    },
    chrome,
    location: { host: url.host, href, pathname: url.pathname },
    sessionStorage: { getItem: (k) => session.get(k) ?? null, setItem: (k, v) => session.set(k, String(v)) },
    document: { readyState: 'complete', addEventListener() {}, activeElement: null, querySelectorAll: () => (dialog ? [dialog] : []) },
    addEventListener: (type, listener) => (listeners[type] = listener),
    alert() {},
    NEFORUM_EXT: {
      manual: true,
      fill,
      panel: {
        mount: (_, a) => {
          actions = a;
          return panel;
        },
      },
      recipeFor: () => recipe,
      postKeys: 'Ctrl+Enter',
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox, { filename: 'main.js' });
  return {
    start: () => onMessage({ type: 'fillNow' }),
    /** The user presses [key] on the page (a real key press). */
    press: (key) => listeners.keydown({ key, isTrusted: true, repeat: false, isComposing: false, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false }),
    /** The panel's buttons, once it is shown. */
    actions: () => actions,
    button,
    pressed,
    inserted,
    statuses,
    session,
  };
}

/** Waits until [ready] holds: the stand-in timers resolve at once, so this is quick. */
async function until(ready, what) {
  const end = Date.now() + 3000;
  while (!ready()) {
    if (Date.now() > end) assert.fail(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 2));
  }
}

const automaticJob = (extra = {}) => ({
  id: 'j_1',
  platformId: 'example',
  platformName: 'Example',
  url: 'https://www.example.test/compose',
  text: 'Hello there',
  media: [],
  quickPost: false,
  autoPost: true,
  preferred: true,
  ...extra,
});

test('automatic job: NEFORUM is asked again right before Post, which is pressed once; the page id goes with every request', async () => {
  const app = standInApp(automaticJob());
  const page = loadPage({ app });
  page.start();
  await until(() => app.state.reports.some((r) => r.posted), 'the posted report');
  assert.equal(page.pressed.length, 1);
  assert.deepEqual(app.state.reports.map((r) => [r.automatic, r.posted]), [['countdown', undefined], ['countdown', 'confirmed']]);
  assert.equal(app.state.pages.length, 2, 'the job at the start, and again before pressing Post');
  assert.match(app.state.pages[0], /^[0-9a-f]{24}$/);
  assert.equal(new Set(app.state.pages).size, 1, 'one id for the whole page');
  assert.deepEqual(app.state.reports.map((r) => r.page), [app.state.pages[0], app.state.pages[0]], 'every report says which page sent it');
});

test('automatic job: Stop or Esc while NEFORUM is asked before Post keeps it unposted', async () => {
  for (const how of ['Esc', 'Stop']) {
    // NEFORUM answers the request before Post only when the test lets it
    // (a background script that has to start again and find NEFORUM's port).
    let answer;
    const answered = new Promise((resolve) => (answer = resolve));
    const app = standInApp((n) => (n === 1 ? automaticJob() : answered.then(() => automaticJob())));
    const page = loadPage({ app });
    page.start();
    await until(() => app.state.pages.length === 2, 'the request before Post');
    if (how === 'Esc') page.press('Escape');
    else page.actions().stop();
    answer();
    await until(() => app.state.reports.some((r) => r.automatic === 'stopped'), `the report after ${how}`);
    assert.equal(page.pressed.length, 0, `${how}: Post is not pressed, though NEFORUM still has this page post it`);
    assert.ok(page.statuses.includes('Stopped. Nothing was posted.'), how);
    assert.deepEqual(app.state.reports.map((r) => [r.automatic, r.posted, r.message]), [
      ['countdown', undefined, ''],
      ['stopped', undefined, 'Stopped on the page before posting.'],
    ]);
  }
});

test('automatic job: Esc while the page is still being filled in keeps it unposted', async () => {
  let opened;
  const opening = new Promise((resolve) => (opened = resolve));
  const app = standInApp(automaticJob());
  const page = loadPage({ app, recipe: { open: () => opening } });
  page.start();
  await until(() => page.statuses.includes('Opening the composer…'), 'the fill');
  page.press('Escape');
  opened();
  await until(() => app.state.reports.some((r) => r.automatic === 'stopped'), 'the stopped report');
  assert.equal(page.pressed.length, 0);
  assert.equal(app.state.pages.length, 1, 'no countdown, so NEFORUM is not even asked before Post');
  assert.ok(page.statuses.includes('Stopped. Nothing was posted. Check the post, then press Post yourself.'));
});

test('automatic job: the site\'s question after Post is answered once, but not after Stop or Esc', async () => {
  // No Stop: Post, then the confirming button of the site's dialog.
  const dialog = { button: { label: 'Upload' } };
  let app = standInApp(automaticJob());
  let page = loadPage({ app, recipe: { afterPostWords: ['Upload'] }, dialog });
  page.start();
  await until(() => app.state.reports.some((r) => r.posted), 'the posted report');
  assert.deepEqual(page.pressed, [page.button, dialog.button]);

  // Esc right after Post: the question stays for the user to answer.
  app = standInApp(automaticJob());
  let afterPost = null;
  page = loadPage({ app, recipe: { afterPostWords: ['Upload'] }, dialog, onPress: (b) => afterPost?.(b) });
  afterPost = (b) => b === page.button && page.press('Escape');
  page.start();
  await until(() => app.state.reports.some((r) => r.posted), 'the posted report');
  assert.deepEqual(page.pressed, [page.button]);
});

test('automatic job: dropped, replaced or no longer automatic in NEFORUM by the time of Post, so nothing is pressed', async () => {
  for (const [later, says, stoppedReport] of [
    [null, 'NEFORUM no longer has this hand-off, so nothing was posted.', false], // Later, Skip, or the scheduled run gave up
    [automaticJob({ id: 'j_2', autoPost: false }), 'NEFORUM no longer has this hand-off, so nothing was posted.', false], // Open composer again
    [automaticJob({ autoPost: false }), 'NEFORUM stopped automatic posting for this hand-off, so nothing was posted.', true], // cancelled, or another tab
  ]) {
    const app = standInApp((n) => (n === 1 ? automaticJob() : later));
    const page = loadPage({ app });
    page.start();
    await until(() => page.statuses.includes(says), says);
    assert.equal(page.pressed.length, 0, says);
    assert.equal(app.state.reports.some((r) => r.posted), false);
    assert.equal(app.state.reports.some((r) => r.automatic === 'stopped'), stoppedReport, 'reported only while NEFORUM still has the job');
  }
});

test('a Post that loaded a new page (a form sent the classic way) is reported from that page, once', async () => {
  const session = new Map([['neforum-posted-j_1', JSON.stringify({ from: 'https://www.weasyl.com/submit/visual', at: 1 })]]);
  const app = standInApp(automaticJob({ platformId: 'weasyl', autoPost: false }));
  const page = loadPage({ app, href: 'https://www.weasyl.com/submission/123', session });
  page.start();
  await until(() => app.state.reports.length === 1, 'the report from the new page');
  assert.equal(app.state.reports[0].posted, 'confirmed', 'the site moved on to another address');
  assert.equal(page.pressed.length, 0, 'nothing is pressed again');
  assert.ok(page.statuses.includes('Already posted from this page.'));

  // A reload reports nothing more.
  const again = loadPage({ app, href: 'https://www.weasyl.com/submission/123', session });
  again.start();
  await until(() => again.statuses.includes('Already posted from this page.'), 'the reloaded page');
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(app.state.reports.length, 1);

  // Still on the page Post was pressed on: pressed, not confirmed.
  const same = standInApp(automaticJob({ autoPost: false }));
  const stayed = loadPage({ app: same, href: 'https://www.example.test/compose', session: new Map([['neforum-posted-j_1', JSON.stringify({ from: 'https://www.example.test/compose', at: 1 })]]) });
  stayed.start();
  await until(() => same.state.reports.length === 1, 'the report');
  assert.equal(same.state.reports[0].posted, 'pressed');
});

test('thread parts: each goes into a box of its own, judged by that box alone', async () => {
  const parts = ['New release notes: https://example.org/blog/2026/10/release-notes (1/3)', 'Details below. (2/3)', 'https://example.org/blog/2026/10/release-notes (3/3)'];
  const app = standInApp(automaticJob({ autoPost: false, text: parts.join('\n\n'), parts }));
  const page = loadPage({ app, recipe: { addPart: async (i) => ({ part: i }) } });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  assert.deepEqual(page.inserted.map((x) => [x.text, !!x.options.fieldOnly]), [
    [parts[0], false],
    [parts[1], true],
    [parts[2], true],
  ]);
});

test('NEFORUM did not take a report: the page says so', async () => {
  const app = standInApp(automaticJob());
  app.state.refuse = true;
  const page = loadPage({ app });
  page.start();
  const says = 'NEFORUM did not take this report: That hand-off has expired. If the post went up, mark it as posted in NEFORUM.';
  await until(() => page.statuses.includes(says), 'the warning');
  assert.equal(page.pressed.length, 1);
});
