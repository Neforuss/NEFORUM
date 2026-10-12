// NEFORUM browser extension: the small panel shown on the page while a post
// is being filled in (content script). Shadow DOM, so the site's styles
// cannot reach it and its styles cannot leak into the site.

(() => {
  const NF = (globalThis.NEFORUM_EXT ??= {});
  if (NF.panel) return;

  // The NEFORUM mark (tools/generate_icons.dart makes the same shape).
  const LOGO =
    '<svg viewBox="0 0 1024 1024" width="22" height="22" aria-hidden="true"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
    '<stop offset="0" stop-color="#9426FF"/><stop offset=".5" stop-color="#7D00FF"/><stop offset="1" stop-color="#5C00C4"/></linearGradient>' +
    '<mask id="w"><rect width="1024" height="1024" fill="#fff"/><circle cx="512" cy="512" r="116.7" fill="#000"/></mask></defs>' +
    '<rect width="1024" height="1024" rx="307" fill="url(#g)"/><g fill="#FF0"><path d="M122.8 512L512 122.8L901.1 512L729.9 512A217.9 217.9 0 0 0 294 512Z"/>' +
    '<path d="M329.1 512A182.8 182.8 0 0 1 694.8 512L628.7 512A116.7 116.7 0 0 0 395.2 512Z"/>' +
    '<path mask="url(#w)" d="M155.3 544.4L868.6 544.4L836.2 576.8L187.7 576.8ZM220.1 609.2L803.8 609.2L771.4 641.7L252.5 641.7ZM285 674.1L738.9 674.1L706.5 706.5L317.4 706.5ZM349.8 738.9L674.1 738.9L641.7 771.4L382.2 771.4ZM414.7 803.8L609.2 803.8L576.8 836.2L447.1 836.2ZM479.5 868.6L544.4 868.6L512 901.1Z"/>' +
    '<circle cx="512" cy="512" r="50.5"/></g></svg>';

  const CSS = `
    :host { all: initial; }
    [hidden] { display: none !important; }
    .p { position: fixed; right: 16px; bottom: 16px; z-index: 2147483647; width: 320px; max-width: calc(100vw - 32px);
      font: 13px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: #f4efff; background: #16062F;
      border: 1px solid #3b1d6e; border-radius: 14px; box-shadow: 0 18px 50px rgba(20, 0, 50, .45); overflow: hidden; }
    .h { display: flex; align-items: center; gap: 10px; padding: 10px 12px; background: #22094a; }
    .h b { font-weight: 700; letter-spacing: .02em; }
    .h span { color: #c9b8ff; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .x { all: unset; cursor: pointer; color: #c9b8ff; font-size: 18px; line-height: 1; padding: 2px 6px; border-radius: 6px; }
    .x:hover, .x:focus-visible { background: #3b1d6e; color: #fff; }
    .b { padding: 10px 12px 12px; display: grid; gap: 8px; }
    .s { color: #e8dcff; }
    .s.ok { color: #b6f5c8; } .s.warn { color: #ffe08a; } .s.err { color: #ffb3b3; }
    ul { margin: 0; padding-left: 18px; color: #d9ccff; } li { margin: 2px 0; }
    .row { display: flex; flex-wrap: wrap; gap: 6px; }
    button.a { all: unset; cursor: pointer; padding: 6px 10px; border-radius: 9px; background: #2c0f5c; color: #fff; font-weight: 600; font-size: 12px; }
    button.a.primary { background: #FFFF00; color: #16062F; }
    button.a:hover, button.a:focus-visible { outline: 2px solid #9d4dff; outline-offset: 1px; }
    .snip { display: flex; align-items: center; gap: 6px; background: #22094a; border-radius: 9px; padding: 5px 6px 5px 9px; }
    .snip span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #e8dcff; }
    .note { color: #a995d9; font-size: 12px; }
    kbd { font: 600 11px/1 ui-monospace, "Cascadia Mono", Menlo, monospace; padding: 2px 5px; border-radius: 5px; background: rgba(22, 6, 47, .18); }
    button.a:not(.primary) kbd { background: #16062F; color: #e8dcff; }
  `;

  const IS_MAC = /Mac|iPhone|iPad/.test(navigator.userAgentData?.platform ?? navigator.platform ?? navigator.userAgent);

  /** Ctrl+Enter, or ⌘+Enter on a Mac. */
  NF.postKeys = IS_MAC ? '⌘+Enter' : 'Ctrl+Enter';

  function el(tag, attrs = {}, ...children) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') e.className = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v);
    }
    for (const c of children) e.append(c);
    return e;
  }

  /**
   * Shows the panel for [job]. [actions] = { fill, insertText, attach,
   * insertSnippet(text), post, stop }. Returns { set, done, setPost, close }.
   */
  function mount(job, actions) {
    document.getElementById('neforum-ext-panel')?.remove();
    const host = el('div', { id: 'neforum-ext-panel' });
    const root = host.attachShadow({ mode: 'closed' });
    const status = el('div', { class: 's', role: 'status', 'aria-live': 'polite' }, 'Getting your post from NEFORUM…');
    const list = el('ul');
    const logo = el('span');
    logo.innerHTML = LOGO;
    const close = () => host.remove();

    const snippets = (job.snippets ?? []).map((s) =>
      el('div', { class: 'snip' }, el('span', { title: s.text }, `${s.label}: ${s.text}`),
        el('button', { class: 'a', onclick: () => navigator.clipboard.writeText(s.text).catch(() => {}) }, 'Copy'),
        el('button', { class: 'a', onclick: () => actions.insertSnippet(s.text) }, 'Insert')),
    );

    // Post now: only a real click (a script's click is not trusted) posts.
    const postBtn = el('button', { class: 'a primary', hidden: '', title: `Press the site's Post button (${NF.postKeys})`, onclick: (e) => e.isTrusted && actions.post?.() },
      'Post now ', el('kbd', {}, NF.postKeys));
    const stopBtn = el('button', { class: 'a', hidden: '', onclick: (e) => e.isTrusted && actions.stop?.() }, 'Stop');
    const fillBtn = el('button', { class: 'a primary', onclick: () => actions.fill() }, 'Fill in again');
    const note = el('div', { class: 'note' },
      job.quickPost ? `Check the post, then press ${NF.postKeys} (or Post now) to post it.` : 'NEFORUM fills in the post. Check it, then press Post yourself.');

    const box = el('div', { class: 'p', role: 'dialog', 'aria-label': `NEFORUM: post to ${job.platformName}` },
      el('div', { class: 'h' }, logo.firstChild, el('b', {}, 'NEFORUM'), el('span', {}, job.platformName),
        el('button', { class: 'x', title: 'Hide', 'aria-label': 'Hide', onclick: close }, '×')),
      el('div', { class: 'b' },
        status,
        list,
        el('div', { class: 'row' },
          postBtn,
          stopBtn,
          fillBtn,
          job.text ? el('button', { class: 'a', title: 'Into the box you clicked last', onclick: () => actions.insertText() }, 'Insert text') : '',
          job.media?.length ? el('button', { class: 'a', onclick: () => actions.attach() }, job.media.length === 1 ? 'Attach file' : `Attach ${job.media.length} files`) : ''),
        ...snippets,
        note));

    root.append(el('style', {}, CSS), box);
    document.documentElement.append(host);

    return {
      set(text, tone = '') {
        status.className = `s ${tone}`;
        status.textContent = text;
      },
      /** Shows what worked and what needs the user. */
      done({ lines = [], tone = 'ok', headline }) {
        status.className = `s ${tone}`;
        status.textContent = headline;
        list.replaceChildren(...lines.map((l) => el('li', {}, l)));
      },
      /**
       * The Post now part: 'off' (not offered), 'ready' (Post now shown),
       * 'busy' (waiting or posting: Stop shown), 'done' (posted).
       */
      setPost(state) {
        postBtn.hidden = state !== 'ready';
        stopBtn.hidden = state !== 'busy';
        fillBtn.className = state === 'ready' ? 'a' : 'a primary';
        fillBtn.hidden = state === 'busy' || state === 'done';
        if (state === 'done') note.textContent = 'Posted from this page. NEFORUM marks the hand-off as done.';
      },
      close,
    };
  }

  NF.panel = { mount };
})();
