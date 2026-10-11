# Write.as and WriteFreely

NEFORUM publishes to **Write.as** and to any self-hosted **WriteFreely** server. Both use the same API.

Status as of October 2026: the API is open and free. You don't need a developer account, app registration or app review. You sign in with your normal username and password.

## Ways to connect

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Open API**, signed in (recommended) | A Write.as account, or an account on a WriteFreely server | Free | Free Write.as accounts can publish only a few new posts per day. That number grows with account age, and fast bursts are refused for a while ("HTTP 429"). Paid Write.as plans are exempt. Self-hosted servers set their own rules. |
| **Open API**, anonymous | Nothing (Write.as) | Free | Anonymous posts can't be edited or deleted from NEFORUM later. |
| **Hand-off** | An account you are signed in to in the browser | Free | NEFORUM copies the post to the clipboard and opens the site. You paste it and press **Publish**. |

## Connect

1. In NEFORUM, add **Write.as / WriteFreely**.
2. **Server**: keep `https://write.as`, or enter your WriteFreely server, for example `https://blog.example.org`.
3. Enter your **Username** and **Password**.
   - NEFORUM sends them once to `POST /api/auth/login` and receives an **access token**.
   - Only the token is stored, never the password.
4. **Blog alias** (optional): the blog to post to, for example `poems` for `write.as/poems`. If you leave it empty, NEFORUM uses your first blog. NEFORUM reads your blogs with `GET /api/me/collections`.
5. **Upload images to Snap.as**: turn this on only for a Write.as account that has Snap.as access. See *Images* below.

If the server answers "User doesn't exist", check the username. NEFORUM only reports a wrong server address when the server doesn't answer like WriteFreely at all.

For **anonymous posting**, leave the username empty.

You don't register any redirect address: there is no OAuth.

When you remove the account, NEFORUM revokes the token with `DELETE /api/auth/me`. Tokens don't expire on their own.

## Posting

- **Body** is Markdown and is sent unchanged. `#hashtags` in the text become the post's tags on the blog. NEFORUM adds the post's tags to the end of the text as `#tags`.
- **Title** is optional.
- **Language** is sent as a two-letter code (`lang`). **Right-to-left** (`rtl`) is turned on automatically for Arabic, Hebrew, Persian, Urdu and other right-to-left languages. You can override it with the option `rtl`.
- **Other options**: `font` (`serif`, `sans` or `mono`) and `slug`. The slug applies to blog posts only.
- Signed-in posts go to `POST /api/collections/{alias}/posts`. The link NEFORUM shows is your blog address plus the post's slug, for example `https://write.as/alice/my-title`.
- Anonymous posts go to `POST /api/posts`. Their link is `https://write.as/{id}`.

### Images

WriteFreely has **no image upload API**. NEFORUM first puts each image at a public address, then adds it to the text as Markdown (`![alt text](url)`):

- **Snap.as**: Write.as's photo host, only when you turned it on. NEFORUM uploads with `POST https://snap.as/api/photos/upload`, using your Write.as token.
- **Otherwise**: the public **media host** you configured in NEFORUM settings, such as S3, R2 or WebDAV.

If neither is set up, posts with images fail with a clear message. Videos can't be posted.

## Hand-off

Write.as and WriteFreely editors can't be filled in from a link. NEFORUM copies the post to the clipboard, with the title as a first line `# Title`, and opens your server. Paste the text into a new post and press **Publish**. The editor uses the first `#` line as the title.

## Known limitations

- **Daily post limits on free Write.as accounts.** NEFORUM reports them as "quota" errors. Write.as doesn't publish the exact numbers.
- **Who can read a post** is set by the blog's own visibility setting on the server (public, unlisted, private or password). It isn't set per post. NEFORUM warns when a post isn't public.
- **No scheduling.** WriteFreely can't hold scheduled posts. NEFORUM schedules them on your device.
- **No threads, no content warnings.**
- **Anonymous posts**: Write.as returns an edit token for each anonymous post, but NEFORUM doesn't keep it. You can't edit or delete these posts through NEFORUM.
- **Self-hosted servers** may have anonymous posting or new sign-ups turned off. NEFORUM then shows the server's own error.

## Sources

- https://developers.write.as/docs/api/
- https://developers.snap.as/docs/api/
- https://discuss.write.as/t/new-rate-limits-on-publishing/2658
- https://writefreely.org/
