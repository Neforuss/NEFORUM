// NEFORUM browser extension: how to fill in each platform's composer
// (content script). A recipe can open the composer, find the text field,
// and say whether media goes in before the text. Anything it does not
// handle falls back to the generic helpers in fill.js, so a site redesign
// degrades to "click the box, the rest still works" instead of breaking.
//
// Recipes never press Post / Share / Publish themselves. They only say where
// that button is (postSelectors, postWords, beforePostWords for a "Next"
// screen first), for the user's own Ctrl+Enter or Post now (main.js).

(() => {
  const NF = (globalThis.NEFORUM_EXT ??= {});
  if (NF.recipes) return;
  const { waitFor, findByText, press, findEditor, visible } = NF.fill;

  /** The link a Tumblr link post's URL field took, if any (see recipes.tumblr). */
  let tumblrLinkDone = false;

  /** The open dialog, if a composer opened in one. */
  const dialog = () => [...document.querySelectorAll('[role="dialog"], dialog[open]')].filter(visible).pop() ?? null;

  /** Waits for a composer to open after [opener] is pressed. */
  async function openWith(opener, { timeout = 6000 } = {}) {
    const el = await waitFor(opener, { timeout });
    if (!el) return false;
    press(el);
    await waitFor(() => findEditor(dialog() ?? document), { timeout });
    return true;
  }

  const recipes = {
    // Composer links already carry the text; media goes into the composer.
    x: {
      root: dialog,
      fileInput: () => document.querySelector('input[data-testid="fileInput"]'),
      postSelectors: ['[data-testid="tweetButton"]', '[data-testid="tweetButtonInline"]'],
      postWords: ['post', 'post all', 'reply'],
    },
    bluesky: { root: dialog, prefer: ['paste', 'input', 'drop'], postSelectors: ['[data-testid="composerPublishBtn"]'], postWords: ['post', 'publish post', 'reply'] },
    threads: { root: dialog },
    linkedin: { root: dialog, postSelectors: ['.share-actions__primary-action'] },
    reddit: { postSelectors: ['#inner-post-submit-button', '#submit-post-button'] },
    tumblr: {
      // NEFORUM opens the full composer (/new/text, /new/photo, /new/video,
      // /new/link, /new/quote, /new/chat, /new/audio), not the text-only
      // share tool. In a link or audio post the link (the track: the "Track
      // link" snippet) goes into Tumblr's URL field, which makes the link
      // card or the player; the rest of the text goes below it. A quote's
      // source is a snippet to Insert.
      async open(job) {
        tumblrLinkDone = false;
        const audio = /\/new\/audio\b/.test(location.pathname);
        const link = audio
          ? (job.snippets ?? []).find((s) => s.label === 'Track link')?.text ?? /https?:\/\/[^\s<>"]+/.exec(job.text ?? '')?.[0]
          : /\/new\/link\b/.test(location.pathname) && /https?:\/\/[^\s<>"]+/.exec(job.text ?? '')?.[0];
        if (!link) return;
        const field = await waitFor(
          () =>
            document.querySelector(
              'input[type="url"], input[placeholder*="URL" i], input[aria-label*="URL" i], input[placeholder*="link" i], [contenteditable="true"][aria-label*="URL" i]' +
                (audio ? ', input[placeholder*="song" i], input[placeholder*="search" i], input[aria-label*="song" i]' : ''),
            ),
          { timeout: 8000 },
        );
        if (!field || !(await NF.fill.insertText(field, link))) return;
        // Tumblr fetches the preview on Enter (or when the field loses focus).
        field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
        field.blur();
        tumblrLinkDone = link;
        await NF.fill.sleep(1500);
      },
      textFor(job) {
        if (!tumblrLinkDone) return job.text;
        return (job.text ?? '').split(tumblrLinkDone).join('').replace(/\n{3,}/g, '\n\n').trim();
      },
      postWords: ['post now', 'post'],
    },
    mastodon: { postSelectors: ['.compose-form__publish button'], postWords: ['post', 'publish', 'publish!', 'toot!'] },
    misskey: { postWords: ['note', 'post'] },

    facebook: {
      // Page or profile: open "What's on your mind?" when the composer is not open yet.
      async open() {
        if (dialog() && findEditor(dialog())) return;
        await openWith(() => findByText('[role="button"], div[tabindex="0"]', /what.?s on your mind|create (a )?post|write something/i));
      },
      root: dialog,
      // Some composers have a Next screen (audience, boost) before Post.
      beforePostWords: ['next'],
    },

    youtube_posts: {
      // The Posts tab of your channel: the post box sits at the top.
      async open() {
        if (findEditor(document, /post|share|mind|update|write/i)) return;
        await openWith(
          () =>
            document.querySelector('ytd-backstage-post-dialog-renderer #placeholder-area, #post-placeholder, ytd-backstage-post-dialog-renderer') ??
            findByText('[role="button"], button, tp-yt-paper-button, div[tabindex], yt-formatted-string', /create (a )?post|share an update|post an update|what.?s on your mind/i),
        );
      },
      editor: () => document.querySelector('ytd-backstage-post-dialog-renderer #contenteditable-root, #contenteditable-root[contenteditable="true"]'),
      postSelectors: ['ytd-backstage-post-dialog-renderer #submit-button button', 'ytd-backstage-post-dialog-renderer #submit-button'],
      // Images need the image option chosen first.
      async beforeMedia() {
        const imageButton = findByText('button, [role="button"], yt-button-shape button', /^\s*(image|images|add image|photo)\s*$/i);
        if (imageButton) press(imageButton);
      },
    },

    substack: {
      async open() {
        if (findEditor(dialog() ?? document, /mind|note|write/i)) return;
        const opened = await openWith(() => findByText('[role="button"], button, div[tabindex="0"]', /what.?s on your mind/i), { timeout: 4000 });
        if (opened) return;
        // Create > Note.
        const create = findByText('button, [role="button"], a', /^\s*create\s*$/i);
        if (create) {
          press(create);
          await openWith(() => findByText('[role="menuitem"], button, a, div[tabindex]', /^\s*note\s*$/i));
        }
      },
      root: () => dialog() ?? document,
      prefer: ['paste', 'input', 'drop'],
    },

    tiktok: {
      // TikTok Studio: upload first, then the caption box appears with the
      // file name in it, which the caption replaces.
      mediaFirst: true,
      replaceText: true,
      editor: () =>
        waitFor(
          () =>
            document.querySelector('.public-DraftEditor-content[contenteditable="true"], [data-e2e="caption_container"] [contenteditable="true"]') ??
            findEditor(document, /caption|description|describe/i),
          { timeout: 30000 },
        ),
      prefer: ['input', 'drop'],
      // Greyed out until the upload is done; Post now waits for it.
      postSelectors: ['button[data-e2e="post_video_button"]', '[data-e2e="post_video_button"]'],
    },

    instagram: {
      // Create > Post, files, two Next screens, then the caption.
      mediaFirst: true,
      async open() {
        if (document.querySelector('[role="dialog"] input[type="file"]')) return;
        const create =
          document.querySelector('svg[aria-label="New post"], svg[aria-label="Create"]')?.closest('a, [role="link"], [role="button"], div[tabindex]') ??
          findByText('a, [role="link"], [role="button"]', /^\s*(create|new post)\s*$/i);
        if (!create) return;
        press(create);
        const post = await waitFor(() => findByText('a, [role="link"], [role="button"], div[tabindex], span', /^\s*post\s*$/i), { timeout: 2500 });
        if (post) press(post);
        await waitFor(() => document.querySelector('[role="dialog"] input[type="file"]'), { timeout: 6000 });
      },
      fileInput: () => document.querySelector('[role="dialog"] input[type="file"]') ?? document.querySelector('form[enctype] input[type="file"], input[type="file"][accept*="image"]'),
      async afterMedia() {
        for (let i = 0; i < 2; i++) {
          const caption = findEditor(document, /caption/i);
          if (caption && /caption/i.test(caption.getAttribute('aria-label') ?? '')) return;
          const next = await waitFor(() => findByText('[role="dialog"] [role="button"], [role="dialog"] button, [role="dialog"] div[tabindex]', /^\s*next\s*$/i), { timeout: 15000 });
          if (!next) return;
          press(next);
          await NF.fill.sleep(1200);
        }
      },
      editor: () => waitFor(() => document.querySelector('[role="dialog"] [aria-label^="Write a caption"]') ?? findEditor(dialog() ?? document, /caption/i), { timeout: 15000 }),
      postRoot: dialog,
      postWords: ['share'],
    },

    pinterest: {
      mediaFirst: true,
      prefer: ['input', 'drop'],
      title: () => findEditor(document, /add a title|title/i),
      editor: () => findEditor(document, /description|tell everyone|detailed description/i),
      postWords: ['publish'],
    },

    google_business: { postWords: ['post', 'publish'] },
    snapchat: { prefer: ['input', 'drop'] },
    whatsapp: {
      prefer: ['paste', 'input'],
      postSelectors: ['button[aria-label="Send"]', '[data-icon="send"]', '[data-icon="wds-ic-send-filled"]'],
      postWords: ['send'],
    },
  };

  /** The recipe for a job (platform id), falling back to the generic one. */
  NF.recipeFor = (platformId) => recipes[platformId] ?? {};
  NF.recipes = recipes;
})();
