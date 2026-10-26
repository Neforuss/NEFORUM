# NEFORUM browser bridge, protocol 1

How the NEFORUM browser extension (Chrome and Firefox) and the NEFORUM desktop app talk.
The app is the server; the extension's background script is the only client.

## Transport

- HTTP on **127.0.0.1** only, on the first port it can open of **52772 to 52779**, then
  **41772 to 41779** (52771 is the OAuth loopback). The extension finds the app by calling
  `GET /v1/hello` on each port in turn, in the same order (the port that answered last first).
- Why two ranges: 52772-52779 lie in Windows' dynamic port range (49152-65535), where Hyper-V
  (used by WSL, Docker and Windows Sandbox) reserves random blocks of ports at startup. Opening a
  reserved port fails with "access forbidden" (error 10013), so the app moves on, and the 4177x
  ports, below that range, are normally free. Extensions before 1.0.1 only look on 52772-52779.
- JSON bodies (UTF-8), except media bytes.
- **No CORS headers**, ever. Web pages therefore cannot read any response; the extension can,
  because its background script has host permission for `http://127.0.0.1/*`.

## Refused requests (403, body `{"error": "..."}`)

1. The `Host` header is not `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding).
2. An `Origin` header is present and does not start with `chrome-extension://`,
   `moz-extension://` or `safari-web-extension://` (requests made by web pages).
3. A path that needs a token has no valid `Authorization: Bearer <token>` (401 instead of 403).

## Endpoints

### `GET /v1/hello` (no token needed)

`200 {"app": "NEFORUM", "version": "1.0.0", "protocol": 1, "paired": true|false}`

`paired` is true only when the request carries a valid token. It lets the extension check its
token without side effects.

### `POST /v1/pair` (no token needed)

Body `{"code": "123456", "browser": "Chrome"}`. The code is the 6-digit pairing code the app
shows in **Settings > Browser extension > Pair a browser**. It is valid for 5 minutes, once,
with at most 5 wrong tries (then it is cancelled and a new one must be made).

- `200 {"token": "<43-char base64url>"}`: the app stores the token in the system keychain with
  the browser name and shows it in the paired list.
- `403 {"error": "That code is wrong or has expired. Make a new one in NEFORUM."}`

### `POST /v1/unpair` (token)

Forgets this token. `204`.

### `GET /v1/job?host=<location.host>&page=<page id>` (token)

The hand-off waiting for this site, if any. `204` when there is none (or it has expired).
A job matches when `host`, without a leading `www.`, equals one of the job's `hosts` without
`www.`.

`page` (added with extension 1.1.0) is a random id the content script makes once per page load
(8 to 64 letters, digits, `-` or `_`) and sends with every request for the job. The app uses it to
let only one page post an automatic job (see `autoPost`).

```json
{
  "id": "j_1f3c...",                // random, new for every "Open" in a hand-off
  "platformId": "youtube_posts",
  "platformName": "YouTube Posts",
  "url": "https://www.youtube.com/@examplechannel/posts",
  "hosts": ["www.youtube.com", "youtube.com", "m.youtube.com"],
  "text": "The post text (clipboardText of the hand-off plan; may be empty)",
  "title": "Optional title (Reddit, Pinterest, blogs) or null",
  "snippets": [{"label": "Answer 1", "text": "Yes"}],
  "media": [{"index": 0, "name": "photo.jpg", "mimeType": "image/jpeg", "size": 123456, "kind": "image"}],
  "steps": "The hand-off's numbered steps (markdown)",
  "quickPost": true,                // the user may post from the page (Ctrl+Enter / Post now)
  "autoPost": false,                // automatic posting: the extension posts by itself (see Rules)
  "parts": ["Part 1", "Part 2"],    // a thread's parts, the first one included (only for a thread)
  "description": "The post's text alone, without title or tags (only when there is text)",
  "tags": ["art", "sketch"],        // tags without # (only when there are some)
  "poll": {                         // only for a poll or quiz
    "kind": "poll" | "quiz",
    "imageOptions": false,          // an image poll: answer i is image i, options are the captions
    "options": ["Tea", "Coffee"],
    "correctIndex": 1,              // quiz only, index into options
    "explanation": "..."            // quiz only, optional
  },
  "artwork": {"maturity": "general" | "mature" | "adult", "aiGenerated": false, "disallowAiTraining": true},
  "createdAt": "2026-10-12T10:00:00Z",
  "expiresAt": "2026-10-12T10:10:00Z",
  "preferred": true                 // this browser is the one NEFORUM opened the page in
}
```

`autoPost`, `parts`, `description`, `tags`, `poll` and `artwork` were added with extension 1.1.0;
older extensions ignore them (they fill the page in and never post by themselves). Fields without
content are left out, except `autoPost`, which is always sent.

`autoPost` is per request too. For an automatic job it is `true` only for one page: the first page
of a browser with `preferred: true` that asks with a `page` id. Every other page (another tab of
the site, a reload, a page that sent no `page`) gets `false` and only fills the job in. It becomes
`false` for that page as well once the app ends automatic posting for the job: the user stopped it
or took over, the hand-off sheet gave up waiting, or the run was cancelled. The job itself stays,
so a post the user makes from the page is still reported.

There is at most one job at a time (the newest). It expires 10 minutes after it was made.

`preferred` is per request: when NEFORUM opened the page in a particular program (the one set
under **Opens in** for the first paired browser, in the user's order, that can start), only paired
browsers set to that same program get `true`. Others must not fill the page in on their own; they
still may when the user asks (the popup's **Fill in this page**). When NEFORUM used the system's
default browser, every paired browser gets `true`.

The `browser` sent when pairing is the extension's best guess at what it runs in: `Firefox`,
`Microsoft Edge`, `Opera`, `Brave`, `Chrome` (only when the "Google Chrome" brand is listed), or
`Chromium-based browser`. The app guesses the program from it; the user can change it.

### `GET /v1/job/<id>/media/<index>` (token)

The file's bytes with its `Content-Type`. `404` for an unknown or expired job or index.

### `POST /v1/job/<id>/result` (token)

What the extension managed to do, so the app's hand-off sheet can say so.
Body `{"status": "filled" | "partial" | "failed", "text": true, "media": 2, "message": "...", "posted": "confirmed" | "pressed", "automatic": "countdown" | "stopped" | "manual", "page": "<page id>"}`.
`204`. The job stays available until it expires, so the user can fill the page in again. The
extension may report more than once for a job (after filling in, then after posting). `404` when
the job is no longer the app's (the hand-off was closed, replaced or has expired): the app did not
take the report, and the extension says so on the page.

`posted` (optional, only for jobs with `quickPost` or `autoPost`): Post was pressed, by the user's
shortcut or by automatic posting. `confirmed` means the composer closed or emptied afterwards (or
the page moved on), and the app then marks the hand-off as posted; `pressed` means Post was pressed
but the page gave no sign. The app ignores `posted` for jobs with neither flag. When pressing Post
loaded a new page before the extension could report (a form sent the classic way), the next page
of the site in that tab reports it once: `confirmed` when its address differs from the page Post
was pressed on, else `pressed`.

`automatic` (optional, only for jobs with `autoPost`; ignored for others):

- `countdown`: everything was filled in; the extension presses Post when its 3-second countdown
  ends. A report with `posted` follows.
- `stopped`: the user pressed Stop or Esc on the page before Post was pressed (during the fill, the
  countdown, the wait for a greyed-out button or the question to the app before a press), or the
  app ended automatic posting before Post was pressed. Nothing was posted.
- `manual`: the extension did not post: something was not filled in, the site asks for a choice
  only the user can make, or no Post button was found. `message` says why. The page stays filled
  in for the user.

`page` (added with extension 1.1.0): the id the reporting page sends with its job requests. For an
`autoPost` job the app takes `automatic` only from the page that posts it (the one that got
`autoPost: true`). A report from any other page (another tab of the site, a reload, another
browser) says nothing about automatic posting; only its `posted` counts. A report of the posting
page without `automatic` and without `posted` comes from a fill the user asked for there (**Fill in
this page**), which never posts by itself: the app reads it as `manual`.

A report on an `autoPost` job without `page`, `automatic` and `posted` comes from an extension
before 1.1.0: the app hands the post back to the user.

## Rules for the extension

- Never press the platform's Post / Share / Publish button on its own, except for a job with
  `autoPost` (below). Otherwise only when the job has `quickPost` and the user, after the page was
  filled in, presses **Ctrl+Enter** (**⌘+Enter**) with a real key press (`isTrusted`) while not
  typing elsewhere on the page, or clicks the panel's **Post now**. Once per job. When the button
  is greyed out (an upload still running), wait for it; Esc or Stop cancels. Two candidate buttons
  at the same distance from the composer means no click.
- Automatic posting: only for a job whose `autoPost` is `true` for this page (the app sets it only
  when the user turned on automatic posting for that network, and only for one page), only in the
  browser the page was opened in (`preferred` not `false`), only on the first fill of the job on
  that page (never after **Fill in again** or a reload), and only when every part was filled in
  and the site's recipe does not need the user. Then show a 3-second countdown in the panel with
  **Stop** (Esc does the same), press Post once, wait for it as above, and report `posted`. Right
  before every press (a Next screen's included, and after any wait for a greyed-out button), ask
  for the job again with the same `page`: press only when the same job comes back with `autoPost`
  `true`. Otherwise press nothing, say so in the panel, and report `automatic` `stopped` when the
  job is still there. In every other case report `automatic` `manual` (or `stopped`) and leave the
  page as it is.
- Stop and Esc: from the start of an automatic job's fill to its press, either one keeps the job
  unposted, whenever it comes: during the fill, the countdown, a wait for a greyed-out button, or
  while the app is asked before a press (check again once the answer is in). Report `automatic`
  `stopped`.
- After Post, a confirmation dialog the recipe knows (`afterPostWords`) may be answered once,
  unless the user pressed Stop or Esc since Post: then the dialog is left to the user.
- Never send anything from the page back to the app other than the result above.
- Keep the token in `storage.local`; forget it on `401`.
