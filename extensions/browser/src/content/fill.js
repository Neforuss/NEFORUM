// NEFORUM browser extension: page-filling helpers (content script).
// Text goes in the way a person's paste would, so the site's own editor
// (React inputs, Draft.js, Lexical, ProseMirror, Quill) takes it as real
// input. Files go into the site's file input, or are pasted or dropped onto
// the composer. Only pressPost presses a Post button, and main.js calls it
// only for the user's own Ctrl+Enter (⌘+Enter) or Post now click.

(() => {
  const NF = (globalThis.NEFORUM_EXT ??= {});
  if (NF.fill) return;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  /** Is [el] on screen and big enough to be something a person would use? */
  function visible(el) {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    const s = getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.05;
  }

  /** Polls [find] until it returns something truthy, or null after [timeout] ms. */
  async function waitFor(find, { timeout = 8000, interval = 150 } = {}) {
    const end = Date.now() + timeout;
    for (;;) {
      let found = null;
      try {
        found = find();
      } catch {
        found = null;
      }
      if (found) return found;
      if (Date.now() > end) return null;
      await sleep(interval);
    }
  }

  /** Text a person would read on [el]: its label, placeholder or text. */
  function label(el) {
    return [el.getAttribute?.('aria-label'), el.getAttribute?.('aria-placeholder'), el.getAttribute?.('placeholder'), el.getAttribute?.('data-placeholder'), el.getAttribute?.('title'), el.textContent]
      .filter(Boolean)
      .join(' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /** The first visible element under [root] matching [selector] whose label matches [pattern]. */
  function findByText(selector, pattern, root = document) {
    for (const el of root.querySelectorAll(selector)) {
      if (visible(el) && pattern.test(label(el))) return el;
    }
    return null;
  }

  /** Clicks [el] the way a mouse would (pointer, mouse and click events). */
  function press(el) {
    if (!el) return false;
    el.scrollIntoView?.({ block: 'center', inline: 'center' });
    const r = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
    for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
      const E = type.startsWith('pointer') && typeof PointerEvent === 'function' ? PointerEvent : MouseEvent;
      el.dispatchEvent(new E(type, at));
    }
    el.click();
    return true;
  }

  const EDITABLE = 'textarea, input[type="text"], input:not([type]), [contenteditable="true"], [contenteditable=""], [contenteditable="plaintext-only"], [role="textbox"]';

  /** The writable element itself (an editor root, not a wrapper). */
  function editableOf(el) {
    if (!el) return null;
    if (el.matches?.('textarea, input')) return el;
    if (el.isContentEditable) {
      // Climb to the editing host so the whole editor gets the text.
      let host = el;
      while (host.parentElement && host.parentElement.isContentEditable) host = host.parentElement;
      return host;
    }
    return el.querySelector?.('[contenteditable="true"], [contenteditable=""], textarea') ?? null;
  }

  /**
   * The composer's text field: the focused one if it is editable, otherwise
   * the best visible candidate under [root] (labelled like a post box, then
   * the biggest).
   */
  function findEditor(root = document, hint = /what.?s on your mind|what.?s happening|write|caption|post|note|share|say|text|message|description|start a thread/i) {
    // Only a focused field itself counts (the page body is not a field).
    const ae = document.activeElement;
    const active = ae && (ae.matches?.('textarea, input') || ae.isContentEditable) ? editableOf(ae) : null;
    if (active && visible(active) && root.contains(active)) return active;
    const seen = new Set();
    const candidates = [];
    for (const el of root.querySelectorAll(EDITABLE)) {
      const e = editableOf(el);
      if (!e || seen.has(e) || !visible(e) || e.closest('[aria-hidden="true"]')) continue;
      if (e.matches('input') && (e.readOnly || e.disabled)) continue;
      seen.add(e);
      const r = e.getBoundingClientRect();
      candidates.push({ e, score: (hint.test(label(e)) ? 1e6 : 0) + (e.matches('input') ? 0 : r.width * r.height) });
    }
    candidates.sort((a, b) => b.score - a.score);
    return candidates[0]?.e ?? null;
  }

  const norm = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();

  /** Does [el] already show [text] (or its start, for long posts)? */
  function hasText(el, text) {
    const want = norm(text).slice(0, 40);
    if (!want) return true;
    const have = norm(el.matches?.('textarea, input') ? el.value : el.innerText ?? el.textContent);
    return have.includes(want);
  }

  const contentOf = (el) => norm(el.matches?.('textarea, input') ? el.value : el.innerText ?? el.textContent);

  /** Does [el] hold exactly [text] (what a replace should leave)? */
  const holdsOnly = (el, text) => contentOf(el) === norm(text);

  /**
   * Waits up to [ms] for [el] to show [text] (or, with [exact], to hold only
   * [text]): editors such as Lexical and React-driven ones update a moment later.
   */
  async function shows(el, text, ms = 1000, exact = false) {
    const end = Date.now() + ms;
    for (;;) {
      if (exact ? holdsOnly(el, text) : hasText(el, text)) return true;
      if (Date.now() > end) return false;
      await sleep(50);
    }
  }

  function placeCaretAtEnd(el) {
    el.focus({ preventScroll: true });
    if (el.matches('textarea, input')) {
      el.setSelectionRange?.(el.value.length, el.value.length);
      return;
    }
    const sel = getSelection();
    const range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    sel.removeAllRanges();
    sel.addRange(range);
  }

  function selectAll(el) {
    el.focus({ preventScroll: true });
    if (el.matches('textarea, input')) {
      el.select();
      return;
    }
    const sel = getSelection();
    const range = document.createRange();
    range.selectNodeContents(el);
    sel.removeAllRanges();
    sel.addRange(range);
  }

  /** Fires a paste carrying [data] (a DataTransfer) at [el]. True if the page took it. */
  function firePaste(el, data) {
    const ev = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true, composed: true });
    // Some browsers drop clipboardData from the constructor; set it back.
    if (!ev.clipboardData) Object.defineProperty(ev, 'clipboardData', { value: data });
    el.dispatchEvent(ev);
    return ev.defaultPrevented;
  }

  function setNativeValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  /**
   * Puts [text] into [el]. With [replace] the field's current text goes
   * (TikTok prefills the file name). Returns the method that worked, or null.
   */
  async function insertText(el, text, { replace = false } = {}) {
    if (!el || !text) return null;
    if (!replace && hasText(el, text)) return 'already';
    const textField = el.matches('textarea, input');

    if (textField) {
      replace ? selectAll(el) : placeCaretAtEnd(el);
      if (document.execCommand('insertText', false, text) && (await shows(el, text, 300))) return 'insertText';
      setNativeValue(el, replace ? text : el.value + text);
      return (await shows(el, text, 300)) ? 'value' : null;
    }

    // Rich editors: a paste first (they all turn pasted plain text into
    // paragraphs), then typing commands, then a raw beforeinput. Each try
    // waits for the editor to show the text, so nothing goes in twice.
    // Editors such as Draft.js learn about a new selection only from the
    // selectionchange event that follows it, so wait a moment after selecting.
    const select = async () => {
      replace ? selectAll(el) : placeCaretAtEnd(el);
      await sleep(80);
    };
    if (replace && contentOf(el)) {
      await select();
      const data = new DataTransfer();
      data.setData('text/plain', text);
      const taken = firePaste(el, data);
      if (await shows(el, text, taken ? 1500 : 400, true)) return 'paste';
      // The paste went next to the old text: clear the field and start over.
      selectAll(el);
      await sleep(80);
      document.execCommand('selectAll');
      document.execCommand('delete');
      await sleep(150);
      if (contentOf(el)) return null;
    }

    await select();
    const data = new DataTransfer();
    data.setData('text/plain', text);
    const taken = firePaste(el, data);
    if (await shows(el, text, taken ? 1500 : 400)) return 'paste';

    await select();
    const lines = text.split('\n');
    lines.forEach((line, i) => {
      if (i > 0) document.execCommand('insertParagraph');
      if (line) document.execCommand('insertText', false, line);
    });
    if (await shows(el, text, 800)) return 'insertText';

    placeCaretAtEnd(el);
    el.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: text, bubbles: true, cancelable: true, composed: true }));
    return (await shows(el, text, 800)) ? 'beforeinput' : null;
  }

  function dataTransferOf(files) {
    const dt = new DataTransfer();
    for (const f of files) dt.items.add(f);
    return dt;
  }

  /** Does a file input's accept list take [file]? */
  function accepts(input, file) {
    const accept = (input.getAttribute('accept') ?? '').toLowerCase();
    if (!accept.trim()) return true;
    const type = (file.type ?? '').toLowerCase();
    const ext = '.' + (file.name.split('.').pop() ?? '').toLowerCase();
    return accept.split(',').map((a) => a.trim()).some((a) => a === type || a === ext || (a.endsWith('/*') && type.startsWith(a.slice(0, -1))));
  }

  /** The best file input under [root] for [files] (hidden ones count: sites hide them). */
  function findFileInput(files, root = document) {
    const inputs = [...root.querySelectorAll('input[type="file"]')].filter((i) => !i.disabled);
    const fit = inputs.filter((i) => files.every((f) => accepts(i, f)) && (files.length < 2 || i.multiple));
    return fit[0] ?? inputs.find((i) => files.every((f) => accepts(i, f))) ?? null;
  }

  /** Gives [files] to a file input as if the user had picked them. */
  function setInputFiles(input, files) {
    input.files = dataTransferOf(files).files;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return input.files.length === files.length;
  }

  /** Drops [files] onto [el] (drag and drop zones). */
  function dropOn(el, files) {
    const dt = dataTransferOf(files);
    const r = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, composed: true, dataTransfer: dt, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
    let taken = false;
    for (const type of ['dragenter', 'dragover', 'drop']) {
      const ev = new DragEvent(type, at);
      if (!ev.dataTransfer) Object.defineProperty(ev, 'dataTransfer', { value: dt });
      el.dispatchEvent(ev);
      if (type === 'drop') taken = ev.defaultPrevented;
    }
    return taken;
  }

  /**
   * Attaches [files]: the composer's file input, else a paste into the
   * editor, else a drop on the composer. Returns the method used, or null.
   */
  async function attachFiles(files, { root = document, editor = null, prefer = ['input', 'paste', 'drop'] } = {}) {
    if (!files.length) return null;
    for (const way of prefer) {
      if (way === 'input') {
        const input = findFileInput(files, root) ?? findFileInput(files, document);
        if (input && setInputFiles(input, files)) return 'input';
      }
      if (way === 'paste') {
        const target = editor ?? findEditor(root);
        if (target) {
          target.focus({ preventScroll: true });
          if (firePaste(target, dataTransferOf(files))) return 'paste';
        }
      }
      if (way === 'drop') {
        const zone = editor ?? findEditor(root) ?? findByText('div, section, label', /drag|drop|upload|select (files|video|photo)/i, root);
        if (zone && dropOn(zone, files)) return 'drop';
      }
    }
    return null;
  }

  // ---- the Post button ------------------------------------------------------

  const BUTTONS = 'button, [role="button"], input[type="submit"]';

  /** What a button says: its label, its text, its value (lower case). */
  const namesOf = (el) =>
    [el.getAttribute('aria-label'), el.matches('input') ? el.value : el.innerText ?? el.textContent].map((s) => norm(s).toLowerCase()).filter(Boolean);

  /** Can a person press [el] now (not greyed out or busy)? */
  function enabled(el) {
    if (!visible(el)) return false;
    if (el.disabled || el.closest('fieldset[disabled]')) return false;
    if (el.closest('[aria-disabled="true"]') || el.getAttribute('aria-busy') === 'true') return false;
    return getComputedStyle(el).pointerEvents !== 'none';
  }

  /**
   * Of [candidates], the one nearest [from] (the editor): the search widens
   * one ancestor at a time and takes the first level holding exactly one.
   * Two at the same distance is ambiguous, so null: better no click than the
   * wrong one. Returns { button, scope } (scope: the ancestor holding both).
   */
  function nearest(candidates, from, root) {
    // A [role=button] wrapping a <button> is one button: keep the inner one.
    const list = candidates.filter((c) => !candidates.some((o) => o !== c && c.contains(o)));
    if (!list.length) return null;
    if (from && from.isConnected) {
      for (let node = from; node && node !== document.documentElement; node = node.parentElement) {
        const near = list.filter((b) => node.contains(b));
        if (near.length === 1) return { button: near[0], scope: node };
        if (near.length > 1) return null;
        if (node === root) break;
      }
    }
    return list.length === 1 ? { button: list[0], scope: root === document ? document.body : root } : null;
  }

  /**
   * The composer's Post button: the first of [selectors] that finds one,
   * else a button that says exactly one of [words]; the one nearest [from]
   * either way. Greyed-out buttons count (they may be waiting for an upload).
   */
  function findPostButton({ from = null, root = document, selectors = [], words = ['post', 'post now', 'publish'] } = {}) {
    root ??= document;
    for (const sel of selectors) {
      const hits = [...root.querySelectorAll(sel)].map((e) => e.closest(BUTTONS) ?? e).filter(visible);
      const found = nearest(hits, from, root);
      if (found) return found;
    }
    const want = new Set(words.map((w) => w.toLowerCase()));
    const hits = [...root.querySelectorAll(BUTTONS)].filter((b) => visible(b) && namesOf(b).some((n) => want.has(n)));
    return nearest(hits, from, root);
  }

  /**
   * After Post was pressed: did the post go? Yes when the page moved on, the
   * composer closed, or the editor emptied (inline composers stay open).
   */
  async function waitPosted({ button, editor = null, text = '', timeout = 25000 }) {
    const from = location.href;
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      await sleep(250);
      if (location.href !== from) return true;
      const buttonGone = !button.isConnected || !visible(button);
      const editorGone = !editor || !editor.isConnected || !visible(editor);
      if (buttonGone && editorGone) return true;
      if (editor && !editorGone && text && contentOf(editor) === '') return true;
    }
    return false;
  }

  /** Presses the Post button (main.js calls this only for the user's own key press or click). */
  const pressPost = (button) => press(button);

  NF.fill = {
    sleep, visible, waitFor, label, findByText, press, findEditor, editableOf, hasText, insertText, attachFiles, findFileInput, setInputFiles, dropOn, firePaste, accepts,
    enabled, findPostButton, waitPosted, pressPost,
  };
})();
