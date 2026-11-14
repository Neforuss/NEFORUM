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
function loadPage({ app, recipe = {}, href = 'https://www.example.test/compose', session = new Map(), dialog = null, onPress = null, posted = async () => true, noButton = false, fileInput = null, pickerInput = null }) {
  const pressed = [];
  const inserted = [];
  const statuses = [];
  const listeners = {};
  const docListeners = {};
  const attachCalls = [];
  const setFiles = [];
  let onMessage = null;
  let actions = null;
  const editor = { isConnected: true };
  /** A stand-in element: [names] is what it says (its label, its text). */
  const element = (names, extra = {}) => ({
    names,
    isConnected: true,
    matches: (sel) => /button/.test(sel),
    closest: () => null,
    querySelector: () => null,
    ...extra,
  });
  const button = element(['post'], { label: 'Post' });
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
    attachFiles: async (files, options) => {
      attachCalls.push(options);
      return null;
    },
    setInputFiles: (input, files) => {
      setFiles.push({ input, files });
      return true;
    },
    findFileInput: () => fileInput,
    isSearchField: (el) => !!el?.search,
    namesOf: (el) => el.names ?? [],
    sleep: () => new Promise((r) => setImmediate(r)),
    enabled: () => true,
    findPostButton: ({ root }) => (noButton ? null : { button: dialog && root === dialog ? dialog.button : button, scope: { contains: () => true } }),
    waitPosted: (options) => posted(options),
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
      // The job's files, one chunk each.
      connect() {
        let listener = null;
        return {
          onMessage: { addListener: (f) => (listener = f) },
          onDisconnect: { addListener() {} },
          postMessage: () => setImmediate(() => listener({ data: Buffer.from('photo').toString('base64'), done: true, type: 'image/png' })),
          disconnect() {},
        };
      },
    },
  };
  const url = new URL(href);
  const sandbox = {
    console,
    atob,
    File,
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
    document: {
      readyState: 'complete',
      addEventListener: (type, listener) => (docListeners[type] = listener),
      activeElement: null,
      querySelectorAll: () => (dialog ? [dialog] : []),
      querySelector: (sel) => (/input\[type="file"\]/.test(sel) ? pickerInput : null),
    },
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
    /** The user presses [key] on the page (a real key press); [ctrl]: with Ctrl. */
    press: (key, { ctrl = false } = {}) =>
      listeners.keydown({ key, isTrusted: true, repeat: false, isComposing: false, ctrlKey: ctrl, metaKey: false, altKey: false, shiftKey: false, preventDefault() {}, stopImmediatePropagation() {} }),
    /** A click on [target] ([trusted]: the user's own; a script's is not). */
    click: (target, { trusted = true } = {}) => docListeners.click({ isTrusted: trusted, target, composedPath: () => [target] }),
    /** The panel's buttons, once it is shown. */
    actions: () => actions,
    element,
    button,
    attachCalls,
    setFiles,
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

const handOff = (extra = {}) => automaticJob({ autoPost: false, quickPost: false, ...extra });

test('I posted it: NEFORUM is told the post is up, once, for a job the extension may not post (TikTok)', async () => {
  const app = standInApp(handOff({ platformId: 'tiktok', platformName: 'TikTok' }));
  const page = loadPage({ app, noButton: true });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  page.actions().markPosted();
  await until(() => app.state.reports.length === 2, 'the posted report');
  assert.equal(app.state.reports[1].posted, 'user');
  assert.ok(page.statuses.includes('Marked as posted on TikTok.'));
  assert.equal(page.pressed.length, 0, 'nothing is pressed on the page');
  page.actions().markPosted();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(app.state.reports.length, 2, 'a second click says nothing more');
  // A reload of the page does not offer it again: the post is done there.
  assert.ok(page.session.has('neforum-posted-j_1'));
});

test('Ctrl+Enter where the Post button cannot be found: the panel points at I posted it', async () => {
  const app = standInApp(handOff({ quickPost: true, platformId: 'tiktok', platformName: 'TikTok' }));
  const page = loadPage({ app, noButton: true });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  page.press('Enter', { ctrl: true });
  assert.ok(page.statuses.some((s) => /Could not find TikTok's Post button: press it on the page\..*I posted it/.test(s)));
  assert.equal(page.pressed.length, 0);
});

test('the user presses the site\'s own Post: watched, and reported once the post went (confirmed)', async () => {
  const app = standInApp(handOff({ platformId: 'tiktok', platformName: 'TikTok' }));
  let seen = null;
  const page = loadPage({ app, noButton: true, recipe: { postSelectors: [], postWords: ['post'], postedPattern: /uploaded/ }, posted: async (o) => ((seen = o), true) });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  // A script's click, or a click on another button, is not the user posting.
  page.click(page.button, { trusted: false });
  page.click(page.element(['discard']));
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(app.state.reports.length, 1);
  page.click(page.button);
  await until(() => app.state.reports.length === 2, 'the posted report');
  assert.equal(app.state.reports[1].posted, 'confirmed');
  assert.equal(seen.button, page.button, 'the button the user pressed is watched');
  assert.deepEqual(seen.posted, /uploaded/, 'with what the site says once a post is up');
  assert.equal(page.pressed.length, 0, 'the extension pressed nothing');
});

test('the user presses Post but the page never shows the post go: nothing is reported (I posted it stays)', async () => {
  const app = standInApp(handOff());
  const page = loadPage({ app, recipe: { postWords: ['post'] }, posted: async () => false });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  page.click(page.button);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(app.state.reports.length, 1);
  page.actions().markPosted();
  await until(() => app.state.reports.length === 2, 'the I posted it report');
  assert.equal(app.state.reports[1].posted, 'user');
});

test('Attach: the recipe\'s photo option and its file input, never a paste into another field', async () => {
  const media = [{ index: 0, name: 'photo.png', mimeType: 'image/png', size: 5, kind: 'image' }];
  const input = { kind: 'post box input' };
  const steps = [];
  const recipe = {
    beforeMedia: async () => steps.push('image option'),
    fileInput: () => (steps.includes('image option') ? input : null),
    afterMedia: async () => steps.push('after'),
  };
  const app = standInApp(handOff({ media }));
  const page = loadPage({ app, recipe });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  page.setFiles.length = 0;
  steps.length = 0;
  await page.actions().attach();
  assert.deepEqual(steps, ['image option', 'after']);
  assert.equal(page.setFiles.length, 1);
  assert.equal(page.setFiles[0].input, input, 'the post box\'s own input');
  assert.equal(page.attachCalls.length, 0, 'neither the fill nor Attach pasted or dropped them anywhere');
  assert.ok(page.statuses.includes('Files added.'));
});

test('Attach where nothing takes the files: the site\'s file window opens for the user to pick them', async () => {
  const media = [{ index: 0, name: 'photo.png', mimeType: 'image/png', size: 5, kind: 'image' }];
  let opened = 0;
  const app = standInApp(handOff({ media }));
  const page = loadPage({ app, pickerInput: { click: () => opened++ } });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  await page.actions().attach();
  assert.equal(opened, 1, 'the site\'s file input is opened, from the user\'s click on Attach');
  assert.ok(page.statuses.some((s) => /^Choose the file in the window that opened/.test(s)));
});

test('an attachOnly recipe (Locals): files its attach did not take stay out, the fill is partial with its help, and an automatic job does not post', async () => {
  const media = [{ index: 0, name: 'clip.mp4', mimeType: 'video/mp4', size: 5, kind: 'video' }];
  let opened = 0;
  // The uploader's own input, once the user opened it: the file window for Attach.
  const uploader = { kind: 'uploader input', click: () => opened++ };
  const recipe = { attach: async () => null, attachOnly: true, mediaHelp: (files) => `Add ${files[0].name} yourself.`, fileInput: () => uploader };
  const app = standInApp(automaticJob({ media }));
  const page = loadPage({ app, recipe, fileInput: { kind: 'found input' } });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  const [report] = app.state.reports;
  assert.equal(report.status, 'partial');
  assert.equal(report.automatic, 'manual');
  assert.match(report.message, /^Not everything was filled in\. Add clip\.mp4 yourself\.$/);
  assert.equal(page.setFiles.length, 0, 'no file input was given the files');
  assert.equal(page.attachCalls.length, 0, 'no paste or drop either');
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(page.pressed.length, 0, 'nothing posted');
  // Attach: the recipe's way, then the site's file window for the user.
  await page.actions().attach();
  assert.equal(page.setFiles.length, 0);
  assert.equal(page.attachCalls.length, 0);
  assert.equal(opened, 1, 'its file window opens for the user to pick the file');
  assert.ok(page.statuses.some((s) => /^Choose the file in the window that opened/.test(s)));
});

test('typeFirst (Locals) goes with the text', async () => {
  const app = standInApp(handOff());
  const page = loadPage({ app, recipe: { typeFirst: true } });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  assert.equal(page.inserted[0].options.typeFirst, true);
});

test('busy() (Locals: an upload still running): Post waits until it ends, and is not pressed while it never does', async () => {
  let checks = 2;
  let app = standInApp(automaticJob());
  let page = loadPage({ app, recipe: { busy: () => checks-- > 0 } });
  page.start();
  await until(() => app.state.reports.some((r) => r.posted), 'the posted report');
  assert.equal(page.pressed.length, 1);
  assert.ok(page.statuses.some((s) => /^Waiting for Example to be ready/.test(s)));
  assert.ok(checks < 0, 'asked until the upload ended');

  app = standInApp(automaticJob());
  page = loadPage({ app, recipe: { busy: () => true } });
  page.start();
  await until(() => app.state.reports.some((r) => r.automatic === 'manual'), 'the not-posted report');
  assert.equal(page.pressed.length, 0);
  assert.equal(app.state.reports.at(-1).message, "Example's Post button stayed greyed out.");
});

test('a composer that does not open fills nothing: failed, not partly filled', async () => {
  const app = standInApp(handOff({ media: [{ index: 0, name: 'photo.png', mimeType: 'image/png', size: 5, kind: 'image' }] }));
  const page = loadPage({ app, recipe: { open: async () => { throw new Error('No post composer here.'); } } });
  page.start();
  await until(() => app.state.reports.length === 1, 'the fill report');
  assert.equal(app.state.reports[0].status, 'failed');
  assert.equal(app.state.reports[0].message, 'No post composer here.');
  assert.equal(page.inserted.length, 0);
});
