// NEFORUM browser extension: how to fill in each platform's composer
// (content script). A recipe can open the composer, find the text field,
// and say whether media goes in before the text. Anything it does not
// handle falls back to the generic helpers in fill.js, so a site redesign
// degrades to "click the box, the rest still works" instead of breaking.
//
// Recipes never press Post / Share / Publish.

(() => {
  const NF = (globalThis.NEFORUM_EXT ??= {});
  if (NF.recipes) return;
  const { waitFor, findByText, press, findEditor, visible } = NF.fill;

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
    x: { root: dialog, fileInput: () => document.querySelector('input[data-testid="fileInput"]') },
    bluesky: { root: dialog, prefer: ['paste', 'input', 'drop'] },
    threads: { root: dialog },
    linkedin: { root: dialog },
    reddit: {},
    tumblr: {},
    mastodon: {},
    misskey: {},

    facebook: {
      // Page or profile: open "What's on your mind?" when the composer is not open yet.
      async open() {
        if (dialog() && findEditor(dialog())) return;
        await openWith(() => findByText('[role="button"], div[tabindex="0"]', /what.?s on your mind|create (a )?post|write something/i));
      },
      root: dialog,
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
    },

    pinterest: {
      mediaFirst: true,
      prefer: ['input', 'drop'],
      title: () => findEditor(document, /add a title|title/i),
      editor: () => findEditor(document, /description|tell everyone|detailed description/i),
    },

    google_business: {},
    snapchat: { prefer: ['input', 'drop'] },
    whatsapp: { prefer: ['paste', 'input'] },
  };

  /** The recipe for a job (platform id), falling back to the generic one. */
  NF.recipeFor = (platformId) => recipes[platformId] ?? {};
  NF.recipes = recipes;
})();
