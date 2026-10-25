// NEFORUM browser extension: content script entry. When NEFORUM has a
// hand-off waiting for this site, it shows the panel, fetches the media
// through the background script, fills in the composer with the site's
// recipe and tells NEFORUM how it went. When the job allows it, the user's
// own Ctrl+Enter (⌘+Enter) or Post now click presses the site's Post button.
// When NEFORUM marked the job automatic (the user turned on automatic
// posting for this site), the extension presses Post itself after a
// 3-second countdown the user can stop, and only when everything was filled
// in.

(() => {
  const NF = (globalThis.NEFORUM_EXT ??= {});
  if (NF.main) return;
  NF.main = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const { waitFor, findEditor, editableOf, insertText, attachFiles, setInputFiles, sleep, enabled, findPostButton, waitPosted, pressPost, visible } = NF.fill;

  /** How long an automatic job's countdown lasts before Post is pressed. */
  const COUNTDOWN_SECONDS = 3;

  async function ask(type, extra = {}) {
    const r = await api.runtime.sendMessage({ type, ...extra });
    if (!r?.ok) throw Object.assign(new Error(r?.error ?? 'The extension did not answer.'), { code: r?.code });
    return r.value;
  }

  /** The editable field the user clicked last (outside our panel). */
  let lastField = null;
  document.addEventListener('focusin', (e) => {
    const f = editableOf(e.target);
    if (f) lastField = f;
  }, true);

  /** Fetches the job's files as File objects, chunk by chunk. */
  function loadMedia(job, onProgress) {
    return new Promise((resolve, reject) => {
      const port = api.runtime.connect({ name: 'neforum-media' });
      const files = [];
      let parts = [];
      let next = 0;
      const request = () => {
        if (next >= job.media.length) {
          port.disconnect();
          resolve(files);
          return;
        }
        onProgress?.(next);
        port.postMessage({ jobId: job.id, index: job.media[next].index });
      };
      port.onMessage.addListener((m) => {
        if (m.error) {
          port.disconnect();
          reject(new Error(m.error));
          return;
        }
        const bin = atob(m.data);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        parts.push(bytes);
        if (!m.done) return;
        const info = job.media[next];
        files.push(new File(parts, info.name, { type: info.mimeType || m.type }));
        parts = [];
        next++;
        request();
      });
      port.onDisconnect.addListener(() => {
        if (next < job.media.length) reject(new Error('The extension stopped while fetching the files.'));
      });
      request();
    });
  }

  let busy = false;
  let files = null;

  /** The editor the text went into, and what the last fill reported. */
  let lastEditor = null;
  let lastResult = null;

  /** The files already attached on this page (names and sizes), so a refill does not add them twice. */
  let attached = null;
  const mediaKey = (job) => JSON.stringify((job.media ?? []).map((m) => [m.name, m.size]));

  /** The other parts of the thread were added on this page, so a refill does not add them twice. */
  let partsAdded = false;

  /** The thread's parts (the first one included), or null for a single post. */
  const partsOf = (job) => (Array.isArray(job.parts) && job.parts.length > 1 ? job.parts : null);

  /** Tells NEFORUM what happened ([extra] goes over the last fill's result). */
  function report(job, extra = {}) {
    const result = { ...(lastResult ?? { status: 'filled', text: !!job.text, media: job.media?.length ?? 0, message: '' }), ...extra };
    ask('result', { jobId: job.id, result }).catch(() => {});
  }

  /**
   * Fills in the composer. [refill]: the user asked again, so NEFORUM's text
   * replaces what is in the box and files already attached are not added again.
   * [automatic]: this fill may end in automatic posting; the result says
   * whether it will ('countdown') or why not ('manual'). Returns that.
   */
  async function fill(job, panel, { refill = false, automatic = false } = {}) {
    if (busy) return null;
    busy = true;
    const recipe = NF.recipeFor(job.platformId);
    const root = () => recipe.root?.() ?? document;
    const parts = partsOf(job);
    const done = { text: true, media: 0, title: !job.title, problems: [], notes: [] };
    let titleExpected = false;
    try {
      panel.set('Opening the composer…');
      await recipe.open?.(job);
      // What goes into the text box: what the recipe says, else the first
      // part of a thread (the others get boxes of their own), else the text.
      const text = recipe.textFor ? recipe.textFor(job) : parts ? parts[0] : job.text;
      done.text = !text;

      if (job.media?.length && !files) {
        files = await loadMedia(job, (i) => panel.set(`Getting ${job.media.length === 1 ? 'the file' : `file ${i + 1} of ${job.media.length}`} from NEFORUM…`));
      }

      const doText = async () => {
        if (!text) return;
        panel.set('Filling in the text…');
        const editor = (await recipe.editor?.()) ?? (await waitFor(() => findEditor(root()), { timeout: 8000 }));
        if (!editor) {
          done.problems.push('Could not find the text box: click into it, then Insert text.');
          return;
        }
        lastEditor = editor;
        done.text = !!(await insertText(editor, text, { replace: !!recipe.replaceText || refill }));
        if (!done.text) done.problems.push('The text box did not take the text: click into it, then Insert text (or paste with Ctrl+V).');
      };

      const doTitle = async () => {
        const title = recipe.titleFor?.(job) ?? job.title;
        if (!title || !recipe.title) return;
        titleExpected = true;
        panel.set('Filling in the title…');
        const field = await recipe.title();
        done.title = !!(field && (await insertText(field, title, { replace: !!recipe.replaceTitle || refill })));
      };

      const doMedia = async () => {
        if (!files?.length) return;
        if (refill && attached === mediaKey(job)) {
          done.media = files.length;
          done.notes.push('The files were already added, so they were not added again (Attach adds them once more).');
          return;
        }
        panel.set(`Adding ${files.length === 1 ? 'the file' : `${files.length} files`}…`);
        // A recipe that places the files itself (an image poll: one per answer).
        if (await recipe.attach?.(files, job)) {
          done.media = files.length;
          attached = mediaKey(job);
          return;
        }
        await recipe.beforeMedia?.();
        await sleep(300);
        let how = null;
        const input = recipe.fileInput?.();
        if (input && setInputFiles(input, files)) how = 'input';
        if (!how) how = await attachFiles(files, { root: root(), editor: findEditor(root()), prefer: recipe.prefer });
        if (how) {
          done.media = files.length;
          attached = mediaKey(job);
          await recipe.afterMedia?.();
        } else {
          done.problems.push('Could not add the files here: use Attach again after opening the media option, or drag them in from NEFORUM\'s Save media to Downloads.');
        }
      };

      // The site's own fields: tags, poll answers, age rating, AI labels.
      const doFields = async () => {
        if (!recipe.fields) return;
        panel.set('Filling in the other fields…');
        const r = await recipe.fields(job, files ?? []);
        if (!r) return;
        done.notes.push(...(r.lines ?? []));
        done.problems.push(...(r.problems ?? []));
        if (r.title) done.title = true;
      };

      // The other parts of a thread, each in a post box of its own.
      const doParts = async () => {
        if (!parts) return;
        if (refill && partsAdded) {
          done.notes.push('The other parts of the thread were already added, so they were not added again.');
          return;
        }
        if (!recipe.addPart) {
          done.problems.push(`This composer takes one post at a time: post the other ${parts.length - 1} parts as replies (they are in this panel).`);
          return;
        }
        let added = 0;
        for (let i = 1; i < parts.length; i++) {
          panel.set(`Adding part ${i + 1} of ${parts.length}…`);
          const box = await recipe.addPart(i);
          if (!box || !(await insertText(box, parts[i]))) break;
          added++;
        }
        if (added > 0) partsAdded = true;
        if (added === parts.length - 1) done.notes.push(`All ${parts.length} parts of the thread filled in.`);
        else if (added > 0) done.problems.push(`Only ${added + 1} of ${parts.length} parts went in: add the rest from this panel.`);
        else done.problems.push(`Could not add the other ${parts.length - 1} parts here: post them as replies (they are in this panel).`);
      };

      // Media goes with the first post of a thread, so before the other parts.
      const steps = recipe.mediaFirst ? [doMedia, doTitle, doText, doFields, doParts] : [doTitle, doText, doMedia, doFields, doParts];
      for (const step of steps) await step();
    } catch (e) {
      done.problems.push(e.message || String(e));
    } finally {
      busy = false;
    }

    const lines = [];
    if (job.text) lines.push(done.text ? 'Text filled in.' : 'Text not filled in.');
    if (job.title) lines.push(done.title ? 'Title filled in.' : 'Add the title yourself.');
    if (job.media?.length) lines.push(done.media ? `${done.media === 1 ? 'File' : `${done.media} files`} added.` : 'Files not added.');
    lines.push(...done.notes, ...done.problems);
    const all = done.text && (!job.media?.length || done.media > 0) && (!titleExpected || done.title);
    const status = all && !done.problems.length ? 'filled' : done.text || done.media ? 'partial' : 'failed';
    lastResult = { status, text: done.text, media: done.media, message: done.problems.join(' ') };

    // Automatic posting goes ahead only when everything went in and the site
    // asks for nothing only the user can decide.
    let state = null;
    if (automatic) {
      const why = status !== 'filled' ? 'Not everything was filled in.' : recipe.manualPublish ?? null;
      state = why ? 'manual' : 'countdown';
      lastResult.automatic = state;
      if (why) lastResult.message = [why, lastResult.message].filter(Boolean).join(' ');
    }
    const check = job.quickPost ? `Check it, then press ${NF.postKeys} to post.` : 'Check it and press Post.';
    panel.done({
      headline:
        state === 'countdown'
          ? `Filled in. Posting on ${job.platformName} in ${COUNTDOWN_SECONDS} seconds…`
          : state === 'manual'
            ? status === 'filled'
              ? `Filled in, not posted automatically. ${recipe.manualPublish}`
              : 'Partly filled in, so not posted automatically. Finish it, then press Post.'
            : status === 'filled'
              ? `Filled in. ${check}`
              : status === 'partial'
                ? 'Partly filled in.'
                : 'Could not fill this page in.',
      tone: status === 'filled' ? 'ok' : status === 'partial' ? 'warn' : 'err',
      lines,
    });
    if (!posted) panel.setPost(state === 'countdown' ? 'busy' : job.quickPost ? 'ready' : 'off');
    report(job);
    return state;
  }

  // ---- posting: the user's own key press or click, or an automatic job ------

  /** The job and panel on this page; [ready]: filling is over, posting may start. */
  let current = null;
  let posting = false;
  let posted = false;
  let counting = false;
  let stopRequested = false;

  /** Where this job's Post button is: { button, scope, before } or null. */
  function locate(job) {
    const recipe = NF.recipeFor(job.platformId);
    const root = recipe.postRoot?.() ?? recipe.root?.() ?? document;
    const editor = lastEditor?.isConnected ? lastEditor : findEditor(root);
    const found = findPostButton({ from: editor, root, selectors: recipe.postSelectors ?? [], words: recipe.postWords, pattern: recipe.postPattern ?? null });
    if (found) return { ...found, editor };
    // A Next screen before Post (Facebook): pressing Next is part of posting.
    const next = recipe.beforePostWords && findPostButton({ from: editor, root, words: recipe.beforePostWords });
    return next ? { ...next, editor, before: true } : null;
  }

  /** Is the user typing somewhere else on the page (a search box, a chat)? */
  function focusedElsewhere(scope) {
    const ae = document.activeElement;
    if (!ae || ae === document.body || ae === document.documentElement || ae.id === 'neforum-ext-panel') return false;
    return !scope.contains(ae);
  }

  /** The dialog on top, if one is open. */
  const topDialog = () => [...document.querySelectorAll('[role="dialog"], [role="alertdialog"], dialog[open]')].filter(visible).pop() ?? null;

  /**
   * After Post: some sites ask once more in a dialog ("Upload 3 photos?",
   * "Did you check the ratings?"). Presses the recipe's confirming button
   * there, once, when one appears.
   */
  async function confirmAfterPost(job, pressed) {
    const words = NF.recipeFor(job.platformId).afterPostWords;
    if (!words?.length) return;
    const found = await waitFor(() => {
      const d = topDialog();
      const b = d && findPostButton({ root: d, words });
      return b && b.button !== pressed && enabled(b.button) ? b : null;
    }, { timeout: 4000, interval: 200 });
    if (found) pressPost(found.button);
  }

  /**
   * Presses Post: waits while it is greyed out (an upload still running),
   * goes through a Next screen if there is one, presses Post once, then
   * watches for the composer to close and tells NEFORUM. Returns what
   * happened: 'posted', 'pressed' (no sign it went), 'stopped', 'greyed'
   * (stayed greyed out), 'missing' (no Post button) or 'busy'.
   */
  async function postNow(target) {
    const c = current;
    if (!c || posting || posted) return 'busy';
    const { job, panel } = c;
    posting = true;
    stopRequested = false;
    panel.setPost('busy');
    const stopped = () => stopRequested;
    try {
      let t = target ?? locate(job);
      for (let step = 0; step < 3 && t; step++) {
        if (!enabled(t.button)) {
          panel.set(`Waiting for ${job.platformName} to be ready (an upload may still be running)… Esc stops.`);
          t = await waitFor(() => {
            if (stopped()) return 'stop';
            const again = locate(job);
            return again && enabled(again.button) ? again : null;
          }, { timeout: 180000, interval: 300 });
          if (t === 'stop' || !t) {
            panel.set(t ? 'Stopped. Nothing was posted.' : 'The Post button stayed greyed out. Check the page, then press Post yourself.', 'warn');
            panel.setPost('ready');
            return t ? 'stopped' : 'greyed';
          }
        }
        if (stopped()) {
          panel.set('Stopped. Nothing was posted.', 'warn');
          panel.setPost('ready');
          return 'stopped';
        }
        if (!t.before) break;
        // The Next screen: press it, then find Post on the next screen.
        pressPost(t.button);
        panel.set('Going to the last screen…');
        const after = await waitFor(() => (stopped() ? 'stop' : (() => {
          const x = locate(job);
          return x && !x.before ? x : null;
        })()), { timeout: 10000 });
        t = after === 'stop' ? null : after;
        if (!t) {
          panel.set(after === 'stop' ? 'Stopped. Nothing was posted.' : 'Could not find the Post button on the next screen: press it yourself.', 'warn');
          panel.setPost(after === 'stop' ? 'ready' : 'off');
          return after === 'stop' ? 'stopped' : 'missing';
        }
      }
      if (!t) {
        panel.set('Could not find the Post button: press it yourself.', 'warn');
        panel.setPost('ready');
        return 'missing';
      }

      // Once per hand-off, even if the page is reloaded.
      posted = true;
      try {
        sessionStorage.setItem(`neforum-posted-${job.id}`, '1');
      } catch {
        // Storage blocked: [posted] still stops a second press on this page.
      }
      panel.set('Posting…');
      pressPost(t.button);
      await confirmAfterPost(job, t.button);
      const ok = await waitPosted({ button: t.button, editor: t.editor, text: job.text });
      panel.done({
        headline: ok ? `Posted on ${job.platformName}.` : 'Pressed Post.',
        tone: ok ? 'ok' : 'warn',
        lines: ok ? [] : [`${job.platformName} did not close the composer. Check the page: it may want something else first. If the post did not go, press its Post button.`],
      });
      panel.setPost(ok ? 'done' : 'off');
      report(job, { posted: ok ? 'confirmed' : 'pressed' });
      return ok ? 'posted' : 'pressed';
    } finally {
      posting = false;
    }
  }

  /** Counts down on the panel; false when the user stopped it (Stop or Esc). */
  async function countdown(job, panel, seconds) {
    stopRequested = false;
    counting = true;
    panel.setPost('busy');
    try {
      for (let s = seconds; s > 0; s--) {
        panel.set(`Posting on ${job.platformName} in ${s}… Stop (or Esc) keeps it unposted.`);
        for (let tick = 0; tick < 10; tick++) {
          if (stopRequested) return false;
          await sleep(100);
        }
      }
      return !stopRequested;
    } finally {
      counting = false;
    }
  }

  /**
   * An automatic job, filled in completely: the countdown, then Post. Tells
   * NEFORUM when it did not post, so the hand-off goes back to the user.
   */
  async function postAutomatically(job, panel) {
    if (!(await countdown(job, panel, COUNTDOWN_SECONDS))) {
      panel.set('Stopped. Nothing was posted. Check the post, then press Post yourself.', 'warn');
      panel.setPost(job.quickPost ? 'ready' : 'off');
      report(job, { automatic: 'stopped', message: 'Stopped on the page before posting.' });
      return;
    }
    const outcome = await postNow(null);
    if (outcome === 'posted' || outcome === 'pressed' || outcome === 'busy') return;
    report(job, {
      automatic: outcome === 'stopped' ? 'stopped' : 'manual',
      message: {
        stopped: 'Stopped on the page before posting.',
        greyed: `${job.platformName}'s Post button stayed greyed out.`,
        missing: `Could not find ${job.platformName}'s Post button.`,
      }[outcome] ?? '',
    });
  }

  // Ctrl+Enter (⌘+Enter): a real key press only (scripts' events are not trusted).
  addEventListener('keydown', (e) => {
    if (!e.isTrusted || e.repeat || e.isComposing) return;
    if (e.key === 'Escape' && (posting || counting)) {
      stopRequested = true;
      return;
    }
    if (e.key !== 'Enter' || !(e.ctrlKey || e.metaKey) || e.altKey || e.shiftKey) return;
    const c = current;
    if (!c?.ready || !c.job.quickPost || posted) return;
    const swallow = () => {
      e.preventDefault();
      e.stopImmediatePropagation();
    };
    if (posting || counting) return swallow();
    if (busy) {
      swallow();
      c.panel.set(`Still filling in. Press ${NF.postKeys} again when it is done.`, 'warn');
      return;
    }
    const target = locate(c.job);
    // No button found: leave the key to the site (some post on Ctrl+Enter themselves).
    if (!target) {
      c.panel.set('Could not find this site\'s Post button: press it yourself.', 'warn');
      return;
    }
    if (focusedElsewhere(target.scope)) return;
    swallow();
    postNow(target);
  }, true);

  /** The newest job for this page (NEFORUM's "Fill in again" makes a new one). */
  async function latest(job) {
    try {
      const { job: fresh } = await ask('job', { host: location.host });
      if (fresh && fresh.id !== job.id) {
        files = null;
        return fresh;
      }
    } catch {
      // Keep the job we have.
    }
    return job;
  }

  async function start(trigger) {
    let job = null;
    try {
      ({ job } = await ask('job', { host: location.host }));
    } catch (e) {
      if (trigger === 'popup') alert(`NEFORUM: ${e.message}`);
      return;
    }
    if (!job) {
      if (trigger === 'popup') alert('NEFORUM: nothing is waiting for this site. In NEFORUM, open the hand-off and click Open.');
      return;
    }
    // NEFORUM opened the page in another browser (the user's first choice):
    // that one fills it in. Here only "Fill in this page" does.
    if (trigger === 'auto' && job.preferred === false) return;

    posted = (() => {
      try {
        return !!sessionStorage.getItem(`neforum-posted-${job.id}`);
      } catch {
        return false;
      }
    })();
    const panel = NF.panel.mount(job, {
      fill: async () => {
        job = await latest(job);
        await fill(job, panel, { refill: true });
      },
      insertText: async () => {
        const target = lastField ?? findEditor(document);
        const ok = target && (await insertText(target, job.text));
        panel.set(ok ? 'Text inserted.' : 'Click into the text box first, then Insert text.', ok ? 'ok' : 'warn');
      },
      attach: async () => {
        job = await latest(job);
        files ??= await loadMedia(job);
        const how = await attachFiles(files, { root: document, editor: lastField ?? findEditor(document), prefer: NF.recipeFor(job.platformId).prefer });
        if (how) attached = mediaKey(job);
        panel.set(how ? 'Files added.' : 'Open the composer\'s photo or video option, then Attach again.', how ? 'ok' : 'warn');
      },
      insertSnippet: async (text) => {
        const target = lastField;
        const ok = target && (await insertText(target, text));
        panel.set(ok ? 'Inserted.' : 'Click into the field first, then Insert.', ok ? 'ok' : 'warn');
      },
      post: () => {
        if (busy) return panel.set(`Still filling in. Press Post now again when it is done.`, 'warn');
        postNow(null);
      },
      stop: () => {
        stopRequested = true;
      },
    });
    current = { job, panel, ready: false };
    if (posted) {
      panel.set('Already posted from this page.', 'ok');
      panel.setPost('done');
      return;
    }

    // Fill in once per hand-off automatically (once per page, for a form
    // over several pages); again only when asked.
    const recipe = NF.recipeFor(job.platformId);
    const key = recipe.stepPages ? `neforum-filled-${job.id}-${location.pathname}` : `neforum-filled-${job.id}`;
    let filledBefore = false;
    try {
      filledBefore = !!sessionStorage.getItem(key);
    } catch {
      filledBefore = false;
    }
    if (trigger === 'auto' && filledBefore) {
      panel.set(job.quickPost ? `Already filled in once. Press ${NF.postKeys} to post, or Fill in again if something is missing.` : 'Already filled in once. Use Fill in again if something is missing.');
      current.ready = true;
      panel.setPost(job.quickPost ? 'ready' : 'off');
      return;
    }
    try {
      sessionStorage.setItem(key, '1');
    } catch {
      // Storage blocked: the panel still works, it may just fill in twice.
    }
    if (document.readyState !== 'complete') await new Promise((r) => addEventListener('load', r, { once: true }));
    await sleep(800); // let the site's own scripts build the composer
    // Automatic posting only for a job NEFORUM marked so, in the browser it
    // opened the page in, and only on its first fill here.
    const automatic = job.autoPost === true && job.preferred !== false && !filledBefore;
    const state = await fill(job, panel, { automatic });
    current.ready = true;
    if (state === 'countdown') await postAutomatically(job, panel);
  }

  api.runtime.onMessage.addListener((msg) => {
    if (msg?.type === 'fillNow') start('popup');
  });
  // Injected from the popup ("Fill in this page"): wait for its fillNow.
  if (!NF.manual) start('auto');
})();
