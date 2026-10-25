// NEFORUM browser extension: page-filling helpers (content script).
// Text goes in the way a person's paste would, so the site's own editor
// (React inputs, Draft.js, Lexical, ProseMirror, Quill) takes it as real
// input. Files go into the site's file input, or are pasted or dropped onto
// the composer. Form fields (title, tags, ratings) are found by the words
// that label them, since sites rename their markup more often than their
// labels. Only pressPost presses a Post button, and main.js calls it only
// for the user's own Ctrl+Enter (⌘+Enter) or Post now click, or, for a job
// NEFORUM marked automatic, when the countdown the user could stop ends.

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

  /**
   * What of [text] comes after [start], when [start] (whitespace collapsed,
   * as contentOf gives it) is how [text] begins; null when it does not
   * begin so. A link that prefilled the first part of a post leaves only the
   * rest to add, so the first part is not put in twice.
   */
  function restAfter(text, start) {
    const s = String(text ?? '');
    const want = norm(start);
    let i = 0;
    let j = 0;
    while (i < s.length && /\s/.test(s[i])) i++;
    while (j < want.length) {
      if (i >= s.length) return null;
      if (/\s/.test(s[i])) {
        // A run of blanks in the text is one space in what the field shows.
        while (i < s.length && /\s/.test(s[i])) i++;
        if (want[j] !== ' ') return null;
        j++;
        continue;
      }
      if (s[i] !== want[j]) return null;
      i++;
      j++;
    }
    return s.slice(i);
  }

  /** Does [el] hold exactly [text] (what a replace should leave)? */
  const holdsOnly = (el, text) => contentOf(el) === norm(text);

  /**
   * Where the rest of [el]'s post can be: block editors (Tumblr) keep every
   * paragraph in an editable of its own, so a paste into one block adds
   * blocks next to it. The open dialog or form, else a few levels up.
   */
  function composerOf(el) {
    const box = el.closest('[role="dialog"], dialog, form');
    if (box) return box;
    let node = el;
    for (let i = 0; i < 3 && node.parentElement && node.parentElement !== document.body; i++) node = node.parentElement;
    return node;
  }

  /** The text of every field in [scope] (not its buttons or counters). */
  function fieldsText(scope) {
    const seen = new Set();
    const parts = [];
    for (const f of scope.querySelectorAll(EDITABLE)) {
      const e = editableOf(f);
      if (!e || seen.has(e)) continue;
      seen.add(e);
      parts.push(e.matches('textarea, input') ? e.value : e.innerText ?? e.textContent);
    }
    return norm(parts.join('\n'));
  }

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
    tellSelection(el);
  }

  /**
   * React editors (Draft.js) take a new selection from React's select event,
   * which a selection set by script doesn't raise; a key-up (of Shift, which
   * types nothing) does.
   */
  function tellSelection(el) {
    el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Shift', code: 'ShiftLeft', bubbles: true, composed: true }));
  }

  function selectAll(el) {
    el.focus({ preventScroll: true });
    if (el.matches('textarea, input')) {
      el.select();
      return;
    }
    // From the first character to the last, not around the editor box:
    // Draft.js maps a selection to its blocks only from inside their text,
    // so a box-wide one over several paragraphs replaces just the last.
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let first = null;
    let last = null;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      first ??= n;
      last = n;
    }
    const sel = getSelection();
    const range = document.createRange();
    if (first && last) {
      range.setStart(first, 0);
      range.setEnd(last, last.length);
    } else {
      range.selectNodeContents(el);
    }
    sel.removeAllRanges();
    sel.addRange(range);
    tellSelection(el);
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
    const scope = composerOf(el);
    if (!replace) {
      // The field shows how the text begins (a link prefilled the first
      // part): only the rest goes in. Checked before the 40-character test
      // below, which would take a long first part for the whole text, and a
      // short one for none of it (and put it in a second time).
      const have = contentOf(el);
      const rest = have && have !== norm(text) ? restAfter(text, have) : null;
      if (rest !== null) return norm(rest) ? insertText(el, rest) : 'already';
    }
    if (!replace && (hasText(el, text) || fieldsText(scope).includes(norm(text).slice(0, 40)))) return 'already';
    // Exactly this text already, over the composer's blocks: nothing to replace.
    if (replace && !el.matches('textarea, input') && fieldsText(scope) === norm(text)) return 'already';
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

    // Once a try has changed the composer, no other try follows, even when
    // the text can't be read back whole: a second one would put it in twice.
    const before = fieldsText(scope);
    const want = norm(text).slice(0, 40);
    const landed = () => hasText(el, text) || fieldsText(scope) !== before;
    const settle = async (ms) => {
      if (!(await waitFor(landed, { timeout: ms, interval: 50 }))) return false;
      // Give a paste that is landing in steps a moment to finish.
      await waitFor(() => fieldsText(scope).includes(want), { timeout: 600, interval: 50 });
      return true;
    };

    await select();
    const data = new DataTransfer();
    data.setData('text/plain', text);
    // An editor that took the paste (preventDefault) may apply it a moment later.
    const taken = firePaste(el, data);
    if (await settle(taken ? 3000 : 400)) return 'paste';

    await select();
    const lines = text.split('\n');
    lines.forEach((line, i) => {
      if (i > 0) document.execCommand('insertParagraph');
      if (line) document.execCommand('insertText', false, line);
    });
    if (await settle(800)) return 'insertText';

    placeCaretAtEnd(el);
    el.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: text, bubbles: true, cancelable: true, composed: true }));
    return (await settle(800)) ? 'beforeinput' : null;
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

  // ---- form fields, found by the words that label them --------------------

  const TEXT_FIELDS =
    'input:not([type]), input[type="text"], input[type="search"], input[type="url"], textarea, [contenteditable="true"], [contenteditable=""], [role="textbox"], [role="combobox"]';
  const CHOICES = 'input[type="checkbox"], input[type="radio"], [role="checkbox"], [role="radio"], [role="switch"]';

  /**
   * The words that label form field [el], one entry per source: its <label>,
   * its ARIA name and placeholder, its name, id or form-control name, and
   * short text right before (or, for a tick box, right after) it.
   */
  function labelsOf(el) {
    const parts = [];
    for (const l of el.labels ?? []) parts.push(l.textContent);
    const by = el.getAttribute?.('aria-labelledby');
    if (by) for (const id of by.split(/\s+/)) parts.push(document.getElementById(id)?.textContent);
    for (const a of ['aria-label', 'placeholder', 'aria-placeholder', 'data-placeholder', 'title', 'name', 'id', 'formcontrolname', 'data-testid']) {
      parts.push(el.getAttribute?.(a));
    }
    parts.push(el.closest?.('label')?.textContent);
    if (el.matches?.('[role="checkbox"], [role="radio"], [role="switch"]')) parts.push(el.textContent);
    if (el.matches?.(CHOICES)) {
      const next = el.nextElementSibling;
      if (next && norm(next.textContent).length <= 100) parts.push(next.textContent);
    }
    // A caption laid out above the field.
    let node = el;
    for (let level = 0; level < 3 && node && node !== document.body; level++) {
      let sib = node.previousElementSibling;
      for (let k = 0; k < 2 && sib; k++, sib = sib.previousElementSibling) {
        const t = norm(sib.textContent);
        if (t && t.length <= 100 && !sib.querySelector?.(`${TEXT_FIELDS}, ${CHOICES}, select`)) parts.push(t);
      }
      node = node.parentElement;
    }
    return parts.filter(Boolean).map(norm).filter(Boolean);
  }

  /** All the words that label form field [el], in one line. */
  const fieldLabel = (el) => labelsOf(el).join(' | ');

  /** Can a person see [el], or the label or box a hidden native tick box sits in? */
  const displayed = (el) => visible(el) || (el.matches?.('input') && (visible(el.closest('label')) || visible(el.labels?.[0]) || visible(el.parentElement)));

  /**
   * The first field under [root] one of whose labels matches [pattern]
   * (each label on its own, so /^NSFW$/ does not take "SFW" or the reverse).
   * [kind]: 'text' (inputs, text areas, rich editors), 'choice' (tick boxes,
   * radio buttons, switches) or 'select' (drop-down lists).
   */
  function findField(pattern, { root = document, kind = 'text' } = {}) {
    const selector = kind === 'choice' ? CHOICES : kind === 'select' ? 'select, [role="combobox"], [role="listbox"]' : TEXT_FIELDS;
    const seen = new Set();
    for (const el of root.querySelectorAll(selector)) {
      const target = kind === 'text' ? editableOf(el) ?? el : el;
      if (!target || seen.has(target)) continue;
      seen.add(target);
      if (!displayed(target) || target.disabled || target.readOnly || target.closest('[aria-hidden="true"]')) continue;
      if (labelsOf(target).some((l) => pattern.test(l))) return target;
    }
    return null;
  }

  /** The group of choices (fieldset, radio group, or a short heading's box) whose heading matches [pattern]. */
  function findGroup(pattern, root = document) {
    for (const g of root.querySelectorAll('fieldset, [role="radiogroup"], [role="group"]')) {
      const head = [g.querySelector('legend')?.textContent, g.getAttribute('aria-label'), ...(g.getAttribute('aria-labelledby') ?? '').split(/\s+/).map((id) => id && document.getElementById(id)?.textContent)]
        .filter(Boolean)
        .map(norm)
        .join(' ');
      if (head && pattern.test(head)) return g;
    }
    for (const h of root.querySelectorAll('legend, label, h1, h2, h3, h4, h5, h6, p, span, div, dt')) {
      if (h.childElementCount > 2) continue;
      const t = norm(h.textContent);
      if (!t || t.length > 80 || !pattern.test(t)) continue;
      for (let box = h.parentElement, i = 0; box && i < 3; box = box.parentElement, i++) {
        if (box.querySelector(`${CHOICES}, select`)) return box;
      }
    }
    return null;
  }

  const isOn = (el) => (el.matches('input') ? el.checked : el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-pressed') === 'true');

  /** Ticks (or unticks) a tick box, radio button or switch. True when it ends up as wanted. */
  async function setChecked(el, on = true) {
    if (!el) return false;
    if (isOn(el) === on) return true;
    // One press: the box itself, or its label when the box is hidden.
    press(el.matches('input') && !visible(el) ? el.closest('label') ?? el.labels?.[0] ?? el : el);
    await sleep(150);
    if (isOn(el) === on) return true;
    if (el.matches('input')) {
      // The page ignored the press: set it the way form libraries listen for.
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'checked').set.call(el, on);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return isOn(el) === on;
  }

  /** Chooses the option whose text (or value) matches [pattern] in a drop-down list. */
  async function chooseOption(list, pattern) {
    if (!list) return false;
    if (list.matches('select')) {
      const option = [...list.options].find((o) => pattern.test(norm(o.textContent)) || pattern.test(o.value));
      if (!option) return false;
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(list, option.value);
      list.dispatchEvent(new Event('input', { bubbles: true }));
      list.dispatchEvent(new Event('change', { bubbles: true }));
      return list.value === option.value;
    }
    // A list drawn by the site: open it, then press the option.
    press(list);
    const option = await waitFor(() => findByText('[role="option"], [role="menuitem"], [role="menuitemradio"], li', pattern), { timeout: 2500 });
    if (!option) return false;
    press(option);
    await sleep(150);
    return true;
  }

  /**
   * Picks the choice labelled [pattern]: a radio button, tick box or switch,
   * or an option of a drop-down list, inside the group headed [group] when
   * given (the age rating of a form, not another question with the same
   * answers).
   */
  async function choose(pattern, { root = document, group = null } = {}) {
    const scope = group ? findGroup(group, root) : root;
    if (!scope) return false;
    const box = findField(pattern, { root: scope, kind: 'choice' });
    if (box) return setChecked(box, true);
    for (const list of scope.querySelectorAll('select')) {
      if (displayed(list) && [...list.options].some((o) => pattern.test(norm(o.textContent)))) return chooseOption(list, pattern);
    }
    return false;
  }

  const pressKey = (el, key, code = key, keyCode = 0) => {
    for (const type of ['keydown', 'keypress', 'keyup']) {
      el.dispatchEvent(new KeyboardEvent(type, { key, code, keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true }));
    }
  };

  /**
   * Puts [tags] into a tag field: one at a time, each confirmed with Enter
   * (fields that turn every tag into a chip), or, with [separator] or when
   * Enter makes no chip, all at once joined by it. Returns how many went in.
   */
  async function insertTags(field, tags, { separator = null, fallbackSeparator = ', ' } = {}) {
    if (!field || !tags?.length) return 0;
    if (separator) return (await insertText(field, tags.join(separator), { replace: true })) ? tags.length : 0;
    let n = 0;
    for (const tag of tags) {
      if (!field.isConnected) break;
      field.focus({ preventScroll: true });
      // Replace, so a tag that also appears in the description still goes in.
      if (!(await insertText(field, tag, { replace: true }))) break;
      pressKey(field, 'Enter', 'Enter', 13);
      await sleep(180);
      if (n === 0 && field.isConnected && contentOf(field) === norm(tag)) {
        // Enter made no chip: a plain field that takes them all at once.
        return (await insertText(field, tags.join(fallbackSeparator), { replace: true })) ? tags.length : 0;
      }
      n++;
    }
    return n;
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
   * else a button that says exactly one of [words] (or matches [pattern],
   * for labels with a count: "Upload 3 photos"); the one nearest [from]
   * either way. Greyed-out buttons count (they may be waiting for an upload).
   */
  function findPostButton({ from = null, root = document, selectors = [], words = ['post', 'post now', 'publish'], pattern = null } = {}) {
    root ??= document;
    for (const sel of selectors) {
      const hits = [...root.querySelectorAll(sel)].map((e) => e.closest(BUTTONS) ?? e).filter(visible);
      const found = nearest(hits, from, root);
      if (found) return found;
    }
    const want = new Set((words ?? []).map((w) => w.toLowerCase()));
    const hits = [...root.querySelectorAll(BUTTONS)].filter((b) => visible(b) && namesOf(b).some((n) => want.has(n) || (pattern && pattern.test(n))));
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

  /**
   * Presses the Post button. main.js calls this only for the user's own key
   * press or click, or when an automatic job's countdown ends unstopped.
   */
  const pressPost = (button) => press(button);

  NF.fill = {
    sleep, visible, waitFor, label, findByText, press, findEditor, editableOf, hasText, insertText, attachFiles, findFileInput, setInputFiles, dropOn, firePaste, accepts,
    enabled, findPostButton, waitPosted, pressPost,
    norm, contentOf, restAfter, labelsOf, fieldLabel, findField, findGroup, setChecked, chooseOption, choose, insertTags, pressKey,
  };
})();
