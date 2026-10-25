// NEFORUM browser extension: how to fill in each platform's composer
// (content script). A recipe can open the composer, find the text field,
// say whether media goes in before the text, add the other parts of a
// thread, and fill the site's own fields (title, tags, poll answers, age
// rating, AI labels). Anything it does not handle falls back to the generic
// helpers in fill.js, so a site redesign degrades to "click the box, the
// rest still works" instead of breaking.
//
// Recipes never press Post / Share / Publish themselves. They only say where
// that button is (postSelectors, postWords, postPattern, beforePostWords for
// a "Next" screen first, afterPostWords for a confirmation after it), for the
// user's own Ctrl+Enter or Post now, or for the end of an automatic job's
// countdown (main.js). manualPublish says why a site must be published by
// the user even when the job is automatic (a choice only the user can make).
//
// Recipe fields (all optional):
//   open(job)              opens the composer
//   root(), postRoot()     where the composer (and its Post button) is
//   editor()               the main text field (may be async)
//   textFor(job)           what goes into it, when not the job's text
//   replaceText            the field holds a placeholder text to replace
//   title(), titleFor(job), replaceTitle
//   mediaFirst, fileInput(), prefer, beforeMedia(), afterMedia()
//   attach(files, job)     adds the files itself (null: the generic way)
//   addPart(index)         adds part [index] of a thread; returns its field
//   fields(job, files)     fills the site's own fields; returns
//                          { lines, problems, title } (title: filled it)
//   stepPages              a form over several pages: fill each page
//   manualPublish          why the user presses Publish even for automatic jobs

(() => {
  const NF = (globalThis.NEFORUM_EXT ??= {});
  if (NF.recipes) return;
  const { waitFor, findByText, press, findEditor, visible, sleep, insertText, setInputFiles, findField, findGroup, choose, setChecked, insertTags } = NF.fill;

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

  /** The text of the job's snippet labelled like [pattern], if any. */
  const snippet = (job, pattern) => (job.snippets ?? []).find((s) => pattern.test(s.label))?.text ?? null;

  /** The job's tags: its own list, else the "Tags" snippet split at commas. */
  function tagsOf(job) {
    if (job.tags?.length) return job.tags;
    const s = snippet(job, /^(tags|keywords)$/i);
    return s ? s.split(/\s*,\s*|\s+#/).map((t) => t.replace(/^#/, '').trim()).filter(Boolean) : [];
  }

  /** Every editable text field under [root] that is on screen, in page order. */
  const editors = (root, selector = '[contenteditable="true"], textarea') => [...(root ?? document).querySelectorAll(selector)].filter(visible);

  /**
   * The post box for part [index] of a thread (0 is the first): the box
   * already there, else the one the control that adds a post ([control])
   * makes. [boxes] lists the thread's boxes in order. Null when there is no
   * such control or no box appeared.
   */
  async function threadPart(index, control, boxes) {
    if (boxes().length > index) return boxes()[index];
    const button = await waitFor(control, { timeout: 4000 });
    if (!button) return null;
    press(button);
    const grown = await waitFor(() => (boxes().length > index ? boxes() : null), { timeout: 5000 });
    return grown ? grown[index] : null;
  }

  /** What a result line says about a field the extension could not find. */
  const missing = (what) => `Could not find the ${what} field: add it yourself (it is in this panel).`;

  // ---- art and portfolio sites ------------------------------------------------

  /**
   * A recipe for an art site's upload form. The fields are found by the
   * words that label them, since these forms could not be studied signed in
   * and their markup changes; every pattern below is a label, not markup.
   *   title, description, tags      label patterns of those fields
   *   tagSeparator                  null: one chip per tag; else the joiner
   *   maturity { group, general, mature, adult }
   *                                 the rating question and its answers;
   *                                 adultBox: a single "adult content" tick box
   *   aiBox / aiGroup + aiYes / aiNo   the "made with AI" question
   *   aiTag, noAiTag                tags some sites use for those labels
   *   noAiBox                       a "do not train AI" tick box
   */
  function artRecipe(spec) {
    const titleField = () => (spec.title === null ? null : findField(spec.title ?? /\btitle\b|作品タイトル|タイトル/i));
    return {
      mediaFirst: spec.mediaFirst ?? true,
      prefer: spec.prefer ?? ['input', 'drop'],
      open: spec.open,
      root: spec.root,
      fileInput: spec.fileInput,
      title: spec.title === null ? undefined : () => waitFor(titleField, { timeout: 8000 }),
      textFor: (job) => (spec.description === null ? null : job.description ?? job.text),
      editor: spec.description === null ? undefined : () => waitFor(() => findField(spec.description ?? /description|caption|comment|about|説明|キャプション/i), { timeout: 6000 }),
      stepPages: spec.stepPages,
      manualPublish: spec.manualPublish,
      postWords: spec.postWords ?? ['post', 'publish', 'submit'],
      postPattern: spec.postPattern,
      afterPostWords: spec.afterPostWords,
      async fields(job, files) {
        const lines = [];
        const problems = [];
        const result = { lines, problems };
        if (spec.before) await spec.before(job, result);
        const art = job.artwork ?? null;
        const tags = [...tagsOf(job)];
        if (art?.aiGenerated && spec.aiTag) tags.push(spec.aiTag);
        if (art?.disallowAiTraining && spec.noAiTag) tags.push(spec.noAiTag);
        if (tags.length && spec.tags !== null) {
          const field = await waitFor(() => findField(spec.tags ?? /tags?|keywords?|タグ/i), { timeout: 4000 });
          const n = field ? await insertTags(field, tags, { separator: spec.tagSeparator ?? null }) : 0;
          if (n >= tags.length) lines.push(`${tags.length === 1 ? 'Tag' : `${tags.length} tags`} added.`);
          else problems.push(field ? `Only ${n} of ${tags.length} tags went in: add the rest yourself.` : missing('tags'));
        }
        if (art) {
          const m = spec.maturity;
          const level = art.maturity ?? 'general';
          let rated = false;
          if (m?.[level]) rated = await choose(m[level], { group: m.group ?? null });
          if (!rated && level !== 'general' && spec.adultBox) rated = await setChecked(findField(spec.adultBox, { kind: 'choice' }), true);
          if (!rated && level === 'mature' && m?.matureBox) rated = await setChecked(findField(m.matureBox, { kind: 'choice' }), true);
          if (rated) lines.push(`Rated ${level === 'general' ? 'for everyone' : level}.`);
          // A site that rates for everyone by default needs nothing for general work.
          else if (level !== 'general' || m?.required) problems.push(`Could not set the ${level === 'general' ? 'age' : level} rating: set it yourself before posting.`);

          if (spec.aiBox || spec.aiGroup) {
            let labelled = false;
            if (spec.aiBox) labelled = await setChecked(findField(spec.aiBox, { kind: 'choice' }), !!art.aiGenerated);
            else labelled = await choose(art.aiGenerated ? spec.aiYes ?? /^yes$|^はい$|あり/i : spec.aiNo ?? /^no$|^いいえ$|なし/i, { group: spec.aiGroup });
            if (labelled && art.aiGenerated) lines.push('Marked as made with AI.');
            if (!labelled && (art.aiGenerated || spec.aiRequired)) problems.push('Could not set the "made with AI" label: set it yourself before posting.');
          } else if (art.aiGenerated && !spec.aiTag) {
            lines.push('This site has no "made with AI" label NEFORUM knows of: say so in the description if its rules ask.');
          }
          if (art.disallowAiTraining && spec.noAiBox) {
            if (await setChecked(findField(spec.noAiBox, { kind: 'choice' }), true)) lines.push('Asked not to be used to train AI.');
            else lines.push('Could not find the "no AI training" option: check it yourself.');
          }
        }
        if (spec.after) await spec.after(job, result, files);
        return result;
      },
    };
  }

  const recipes = {
    // Composer links already carry the text; media goes into the composer,
    // and the other parts of a thread into the post boxes added below it.
    x: {
      root: dialog,
      fileInput: () => document.querySelector('input[data-testid="fileInput"]'),
      postSelectors: ['[data-testid="tweetButton"]', '[data-testid="tweetButtonInline"]'],
      postWords: ['post', 'post all', 'reply'],
      addPart: (i) =>
        threadPart(
          i,
          () => document.querySelector('[data-testid="addButton"]') ?? findByText('button, [role="button"]', /^add (post|another post)$/i, dialog() ?? document),
          () => editors(dialog() ?? document, '[data-testid^="tweetTextarea_"][contenteditable="true"], [data-testid^="tweetTextarea_"] [contenteditable="true"]'),
        ),
    },
    bluesky: {
      root: dialog,
      prefer: ['paste', 'input', 'drop'],
      postSelectors: ['[data-testid="composerPublishBtn"]'],
      postWords: ['post', 'post all', 'publish post', 'reply'],
      addPart: (i) =>
        threadPart(
          i,
          () => findByText('button, [role="button"]', /^(add (new|another) post|add post to thread|add to thread)$/i, dialog() ?? document),
          () => editors(dialog() ?? document, '[data-testid="composerTextInput"] [contenteditable="true"], .ProseMirror[contenteditable="true"]'),
        ),
    },
    threads: {
      root: dialog,
      postWords: ['post'],
      addPart: (i) =>
        threadPart(
          i,
          () => findByText('[role="button"], button, div[tabindex="0"], span', /^add to thread$/i, dialog() ?? document),
          () => editors(dialog() ?? document, '[contenteditable="true"][role="textbox"]').filter((e) => !/topic/i.test(NF.fill.fieldLabel(e))),
        ),
    },
    linkedin: { root: dialog, postSelectors: ['.share-actions__primary-action'] },
    reddit: {
      postSelectors: ['#inner-post-submit-button', '#submit-post-button'],
      manualPublish: 'Reddit asks for a community and often a flair: choose them, then post.',
    },
    tumblr: {
      // NEFORUM opens the full composer (/new/text, /new/photo, /new/video,
      // /new/link, /new/quote, /new/chat, /new/audio), not the text-only
      // share tool. In a link or audio post the link (the track: the "Track
      // link" snippet) goes into Tumblr's URL field, which makes the link
      // card or the player; the rest of the text goes below it. A quote's
      // source is a snippet to Insert. The tags go into the tags field.
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
      async fields(job) {
        const tags = tagsOf(job);
        if (!tags.length) return null;
        const field = await waitFor(
          () =>
            document.querySelector('textarea[placeholder*="tags" i], input[placeholder*="tags" i], [aria-label*="tags" i][contenteditable="true"], input[aria-label*="tags" i]') ??
            findField(/tags/i),
          { timeout: 4000 },
        );
        const n = field ? await insertTags(field, tags) : 0;
        return n >= tags.length
          ? { lines: [`${tags.length === 1 ? 'Tag' : `${tags.length} tags`} added.`], problems: [] }
          : { lines: [], problems: [field ? `Only ${n} of ${tags.length} tags went in: add the rest with Insert.` : 'Could not find the tags field: click it, then Insert the tags.'] };
      },
      postWords: ['post now', 'post'],
    },
    mastodon: {
      postSelectors: ['.compose-form__publish button'],
      postWords: ['post', 'publish', 'publish!', 'toot!'],
      // Mastodon's own composer holds one post; composers that hold a whole
      // thread (some servers' web apps) have a control to add a post.
      addPart: (i) =>
        threadPart(
          i,
          () => findByText('button, [role="button"]', /^(add (a |another )?post|add to thread|continue thread|thread)$/i),
          () => editors(document, '.compose-form textarea, textarea[name="text"]'),
        ),
    },
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
      postSelectors: ['ytd-backstage-post-dialog-renderer #submit-button button', 'ytd-backstage-post-dialog-renderer #submit-button', '#post-button button', '#post-button'],
      // Images need the image option chosen first.
      async beforeMedia() {
        const imageButton = findByText('button, [role="button"], yt-button-shape button', /^\s*(image|images|add image|photo)\s*$/i, youTubePostBox());
        if (imageButton) press(imageButton);
      },
      // An image poll: each image goes into its own answer.
      async attach(files, job) {
        if (!job.poll?.imageOptions) return null;
        const editor = await openYouTubePoll(job.poll);
        if (!editor) return null;
        let n = 0;
        for (let i = 0; i < files.length; i++) {
          const inputs = [...editor.querySelectorAll('input[type="file"]')];
          if (inputs.length <= i) await addYouTubeAnswer(editor, () => editor.querySelectorAll('input[type="file"]').length > i);
          const input = editor.querySelectorAll('input[type="file"]')[i];
          if (input && setInputFiles(input, [files[i]])) n++;
          await sleep(400);
        }
        return n === files.length ? 'options' : null;
      },
      async fields(job) {
        const poll = job.poll;
        if (!poll?.options?.length) return null;
        const lines = [];
        const problems = [];
        const kind = poll.imageOptions ? 'image poll' : poll.kind === 'quiz' ? 'quiz' : 'poll';
        const editor = await openYouTubePoll(poll);
        if (!editor) return { lines, problems: [`Could not open the ${kind} option: choose it, then Insert the answers from this panel.`] };
        let filled = 0;
        for (let i = 0; i < poll.options.length; i++) {
          let boxes = youTubeAnswerFields(editor);
          if (boxes.length <= i) {
            await addYouTubeAnswer(editor, () => youTubeAnswerFields(editor).length > i);
            boxes = youTubeAnswerFields(editor);
          }
          if (boxes[i] && (await insertText(boxes[i], poll.options[i], { replace: true }))) filled++;
        }
        if (filled === poll.options.length) lines.push(`The ${kind}'s ${filled} ${poll.imageOptions ? 'captions' : 'answers'} added.`);
        else problems.push(`Only ${filled} of ${poll.options.length} ${poll.imageOptions ? 'captions' : 'answers'} went in: Insert the rest from this panel.`);
        if (poll.kind === 'quiz' && Number.isInteger(poll.correctIndex)) {
          const marks = [...editor.querySelectorAll('input[type="radio"], [role="radio"], tp-yt-paper-radio-button, [aria-label*="correct" i]')].filter((e) => visible(e) || visible(e.parentElement));
          const mark = marks[poll.correctIndex];
          if (mark && (await setChecked(mark, true))) lines.push(`Answer ${poll.correctIndex + 1} marked as correct.`);
          else problems.push(`Mark answer ${poll.correctIndex + 1} as correct yourself.`);
        }
        if (poll.kind === 'quiz' && poll.explanation) {
          const field = findField(/explanation|explain/i, { root: editor }) ?? findField(/explanation|explain/i, { root: youTubePostBox() });
          if (field && (await insertText(field, poll.explanation, { replace: true }))) lines.push('Explanation added.');
          else problems.push('Could not find the explanation field: Insert it from this panel.');
        }
        return { lines, problems };
      },
    },

    // A video upload: youtube.com/upload forwards to YouTube Studio's upload
    // dialog. The video goes in first; then the title (Studio puts the file
    // name there) and the description. The audience question ("made for
    // kids") is the user's own answer, so posting stays with the user.
    youtube: {
      mediaFirst: true,
      prefer: ['input', 'drop'],
      async open() {
        if (document.querySelector('ytcp-uploads-file-picker, ytcp-uploads-dialog')) return;
        const create = document.querySelector('#create-icon, ytcp-button#create-icon');
        if (create) {
          press(create);
          const upload = await waitFor(() => findByText('tp-yt-paper-item, [role="menuitem"], ytcp-text-menu tp-yt-paper-item', /upload videos?/i), { timeout: 4000 });
          if (upload) press(upload);
        }
        await waitFor(() => document.querySelector('ytcp-uploads-file-picker input[type="file"], input[type="file"][name="Filedata"]'), { timeout: 15000 });
      },
      fileInput: () => document.querySelector('ytcp-uploads-file-picker input[type="file"], input[type="file"][name="Filedata"]'),
      title: () =>
        waitFor(() => document.querySelector('ytcp-video-title #textbox, #title-textarea #textbox, ytcp-social-suggestions-textbox#title-textarea [contenteditable="true"]') ?? null, {
          timeout: 45000,
        }),
      titleFor: (job) => snippet(job, /^title$/i) ?? job.title,
      replaceTitle: true,
      editor: () => waitFor(() => document.querySelector('ytcp-video-description #textbox, #description-textarea #textbox, ytcp-social-suggestions-textbox#description-textarea [contenteditable="true"]'), { timeout: 15000 }),
      async fields(job) {
        const tags = tagsOf(job);
        if (!tags.length) return null;
        const more = findByText('ytcp-button, button, [role="button"]', /^show more$/i);
        if (more) {
          press(more);
          await sleep(600);
        }
        const field = await waitFor(() => document.querySelector('ytcp-free-text-chip-bar input, #tags-container input, input[aria-label="Tags" i]') ?? findField(/^tags|add tag/i), { timeout: 4000 });
        const n = field ? await insertTags(field, tags) : 0;
        return n >= tags.length ? { lines: [`${tags.length === 1 ? 'Tag' : `${tags.length} tags`} added.`], problems: [] } : { lines: [], problems: [field ? `Only ${n} of ${tags.length} tags went in.` : missing('tags')] };
      },
      manualPublish: 'YouTube asks whether the video is made for kids: answer it, go through the next screens and publish.',
      postWords: ['publish', 'save'],
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
      manualPublish: 'WhatsApp asks who gets it: choose a chat, My status or a Channel, then send.',
    },

    // ---- art and portfolio sites (hand-off; see artRecipe) ----

    // Behance: the project editor. Title, tags and the adult flag are in its
    // Settings window; publishing needs a cover crop and a creative field.
    behance: artRecipe({
      title: null,
      description: null,
      tags: null,
      async before(job, result) {
        const open = findByText('button, [role="button"]', /^(continue|settings)$/i);
        if (open) {
          press(open);
          await sleep(1200);
        }
        if (job.title) {
          const field = await waitFor(() => findField(/project title|^title|title/i), { timeout: 5000 });
          if (field && (await insertText(field, job.title, { replace: true }))) result.title = true;
          else result.problems.push(missing('title'));
        }
        const tags = tagsOf(job);
        if (tags.length) {
          const field = findField(/tags/i);
          const n = field ? await insertTags(field, tags.slice(0, 10)) : 0;
          if (n) result.lines.push(`${n === 1 ? 'Tag' : `${n} tags`} added.`);
          else result.problems.push(missing('tags'));
        }
        if (job.description) result.lines.push('Add the description under Co-owners, Credits, and More (it is in this panel).');
      },
      adultBox: /adult content/i,
      maturity: { general: null, mature: null, adult: null },
      manualPublish: 'Behance needs a cover image crop and at least one creative field: choose them, then publish.',
    }),

    artstation: artRecipe({
      maturity: { matureBox: /mature content|has mature/i },
      adultBox: /mature content|has mature/i,
      aiTag: 'CreatedWithAI',
      noAiTag: 'NoAI',
      postWords: ['publish', 'save'],
      postPattern: /^publish( project)?$/i,
    }),

    // Cara: the composer opens from its Post button; one text box, no title.
    cara: artRecipe({
      mediaFirst: false,
      prefer: ['input', 'paste', 'drop'],
      root: dialog,
      async open() {
        if (dialog() && findEditor(dialog())) return;
        await openWith(() => findByText('button, a, [role="button"]', /^(create|new post|post)$/i));
      },
      title: null,
      description: /post|write|caption|share|text/i,
      tags: null,
      maturity: {},
      postWords: ['post'],
    }),

    pixiv: artRecipe({
      tagSeparator: null,
      maturity: {
        group: /age restriction|年齢制限|閲覧制限/i,
        general: /all ages|全年齢/i,
        mature: /all ages|全年齢/i,
        adult: /^r-?18$/i,
        matureBox: /sexual|sensitive|性的/i,
        required: true,
      },
      aiGroup: /ai.generated|ai生成|ai-generated/i,
      aiRequired: true,
      postWords: ['post', 'submit', '投稿する', '投稿'],
    }),

    itaku: artRecipe({
      maturity: { group: /maturity|rating/i, general: /^sfw$/i, mature: /questionable/i, adult: /^nsfw$/i, required: true },
      postWords: ['submit', 'upload', 'post'],
      afterPostWords: ['yes', 'confirm', 'submit', 'ok', 'yes, submit'],
    }),

    newgrounds: artRecipe({
      maturity: {},
      manualPublish: 'Newgrounds asks rating questions and for your agreement to its terms: answer them, then publish.',
    }),

    // Fur Affinity submits over several pages: the type, the file, then the
    // details. Each page is filled in as it opens.
    furaffinity: artRecipe({
      stepPages: true,
      async open() {
        const artwork = findField(/^artwork|visual art|submission/i, { kind: 'choice' });
        if (artwork) await setChecked(artwork, true);
      },
      description: /description|message/i,
      tags: /keywords|tags/i,
      tagSeparator: ' ',
      maturity: { group: /rating/i, general: /^general$/i, mature: /^mature$/i, adult: /^adult$/i, required: true },
      manualPublish: 'Fur Affinity submits in steps: press Next on each page, then Finalize.',
    }),

    weasyl: artRecipe({
      tagSeparator: ' ',
      maturity: { group: /rating/i, general: /general/i, mature: /mature/i, adult: /explicit/i, required: true },
      postWords: ['continue', 'submit'],
    }),

    kofi: artRecipe({
      async open() {
        if (document.querySelector('input[type="file"]')) return;
        const add = findByText('button, a, [role="button"]', /add (an )?image|upload (an )?image|image post|add to gallery/i);
        if (add) {
          press(add);
          await waitFor(() => document.querySelector('input[type="file"]'), { timeout: 5000 });
        }
      },
      maturity: {},
      postWords: ['publish', 'post', 'add to gallery'],
    }),

    artfol: artRecipe({
      async open() {
        if (document.querySelector('input[type="file"]')) return;
        const create = findByText('button, a, [role="button"]', /^(upload|post|create|new post|share artwork)$/i);
        if (create) {
          press(create);
          await waitFor(() => document.querySelector('input[type="file"]'), { timeout: 5000 });
        }
      },
      description: /caption|description|write/i,
      maturity: {},
      postWords: ['post', 'publish', 'upload'],
    }),

    fivehundredpx: artRecipe({
      tags: /keywords?|tags?/i,
      adultBox: /nsfw|mature|adult/i,
      maturity: {},
      postWords: ['publish', 'upload'],
    }),

    // Dribbble: title and the shot, then Continue opens the last screen with
    // the tags.
    dribbble: artRecipe({
      title: /give (me|it) a name|title|name/i,
      description: /description|write|tell/i,
      tags: null,
      maturity: {},
      async after(job, result) {
        const tags = tagsOf(job).slice(0, 20);
        if (!tags.length) return;
        const next = findByText('button, [role="button"]', /^continue$/i);
        if (next) {
          press(next);
          await sleep(1200);
        }
        const field = await waitFor(() => findField(/tags?/i, { root: dialog() ?? document }), { timeout: 5000 });
        const n = field ? await insertTags(field, tags) : 0;
        if (n >= tags.length) result.lines.push(`${tags.length === 1 ? 'Tag' : `${tags.length} tags`} added.`);
        else result.problems.push(field ? `Only ${n} of ${tags.length} tags went in.` : missing('tags'));
      },
      postWords: ['publish', 'publish now'],
    }),

    // Flickr: files first, then each photo's title, description and tags,
    // and the safety level; "Upload N photos", then a confirmation.
    flickr: artRecipe({
      prefer: ['input', 'drop'],
      title: /add a title|title/i,
      description: /add a description|description/i,
      tags: /add tags|tags/i,
      maturity: { group: /safety/i, general: /^safe$/i, mature: /^moderate$/i, adult: /^restricted$/i },
      postPattern: /^upload( \d+)?( photos?| videos?| items?)?$/i,
      postWords: ['upload'],
      afterPostWords: ['upload'],
    }),
  };

  // ---- YouTube Posts: polls and quizzes ---------------------------------------

  /** The post box (YouTube's post dialog), or the page. */
  const youTubePostBox = () => document.querySelector('ytd-backstage-post-dialog-renderer') ?? document;

  const YOUTUBE_POLL_EDITORS =
    '#poll-attachment, #quiz-attachment, ytd-backstage-poll-editor-renderer, ytd-backstage-quiz-editor-renderer, ytd-backstage-image-poll-editor-renderer, ytd-backstage-image-poll-editor';

  /** Opens the poll, image poll or quiz option of the post box; returns its editor (null when it did not open). */
  async function openYouTubePoll(poll) {
    const box = youTubePostBox();
    const open = () => box.querySelector(poll.imageOptions ? 'ytd-backstage-image-poll-editor-renderer, ytd-backstage-image-poll-editor' : poll.kind === 'quiz' ? '#quiz-attachment, ytd-backstage-quiz-editor-renderer' : '#poll-attachment, ytd-backstage-poll-editor-renderer');
    if (open()) return open();
    const buttons = 'button, [role="button"], yt-button-shape button, tp-yt-paper-button, ytd-button-renderer';
    const words = poll.imageOptions ? /^(image poll|add image poll)$/i : poll.kind === 'quiz' ? /^(quiz|add quiz)$/i : /^(poll|text poll|add poll|add text poll)$/i;
    let button = findByText(buttons, words, box);
    // An image poll may be a choice inside the poll option.
    if (!button && poll.imageOptions) {
      const pollButton = findByText(buttons, /^(poll|add poll)$/i, box);
      if (pollButton) {
        press(pollButton);
        await sleep(600);
        button = findByText(buttons, /image poll|images?/i, box);
      }
    }
    if (!button) return null;
    press(button);
    return (await waitFor(open, { timeout: 4000 })) ?? (await waitFor(() => box.querySelector(YOUTUBE_POLL_EDITORS), { timeout: 1500 }));
  }

  /** The answer (or caption) fields of a poll or quiz editor, in order (not the explanation). */
  const youTubeAnswerFields = (editor) =>
    [...editor.querySelectorAll('input:not([type]), input[type="text"], textarea, [contenteditable="true"]')].filter(
      (e) => visible(e) && !/explanation|explain/i.test(NF.fill.fieldLabel(e)),
    );

  /** Presses "Add option" (or answer) until [enough] says there are enough fields. */
  async function addYouTubeAnswer(editor, enough) {
    const button = findByText('button, [role="button"], yt-button-shape button, tp-yt-paper-button', /add (another )?(option|answer|choice)/i, editor) ??
      findByText('button, [role="button"]', /add (another )?(option|answer|choice)/i, youTubePostBox());
    if (!button) return false;
    press(button);
    return !!(await waitFor(enough, { timeout: 2500 }));
  }

  /** The recipe for a job (platform id), falling back to the generic one. */
  NF.recipeFor = (platformId) => recipes[platformId] ?? {};
  NF.recipes = recipes;
  NF.recipeHelpers = { tagsOf, snippet };
})();
