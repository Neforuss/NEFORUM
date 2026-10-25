# Hashnode setup guide

This guide connects a Hashnode blog to NEFORUM with a Personal Access Token, so NEFORUM publishes your articles automatically.

> **Important: API access needs Hashnode Pro.** On 13 May 2026, Hashnode started requiring the paid **Pro** plan on a blog for *every* API request, reads and writes alike. Without Pro, Hashnode answers *"Publication does not have an active Pro plan"*. The hand-off option is free and works on any plan.

## Steps

1. If you haven't already, put your blog on Pro: open the blog **Dashboard > Billing > Upgrade to Pro**.
2. Open **Account settings > Developer**: https://hashnode.com/settings/developer
3. Press **Generate new token** and name it `NEFORUM`.
4. Copy the token. Treat it like a password: it can publish, edit and delete posts on all your blogs.
5. In NEFORUM, add **Hashnode** and paste the token.
6. Enter your blog's address, either `alice.hashnode.dev` or your custom domain.
   - You can also enter the 24-character publication id.
   - If you have only one blog, leave the address empty.
7. Press **Connect**.

## Steps: Hand-off without Pro

1. In NEFORUM, add **Hashnode**, choose **Hand off to the app** and click **Add Hashnode**.
2. Publish the post in NEFORUM. It copies your article (Markdown) to the clipboard and opens https://hashnode.com/.
3. Start a new draft on your blog.
4. Paste the article.
5. Add the title and tags.
6. Upload any images.
7. Press **Publish**.

## How it works

NEFORUM uses Hashnode's GraphQL API at `https://gql-beta.hashnode.com`. That is the production address in Hashnode's own API skill, and `apidocs.hashnode.com` redirects there. The old `https://gql.hashnode.com` now answers every request, POST included, with a redirect to an announcement page (checked 2026-10-11).

| Tier | What you need | Cost | Limits |
|---|---|---|---|
| **Your own API key** (Personal Access Token) | A Hashnode account and a blog on **Hashnode Pro** | Pro is billed per seat. Third-party coverage reports about $5 per seat per month; check your dashboard for the current price. | Published targets of 500 write calls per minute (not enforced). A post with *n* images uses 1 + 2*n* write calls. |
| **Hand-off** | A Hashnode account, signed in in your browser | Free | NEFORUM copies the article to the clipboard and opens Hashnode. You paste it and press **Publish**. |

There's no OAuth app, redirect address or review. The token doesn't expire until you revoke it on the same page.

When you connect, NEFORUM runs the `me` query. If you entered a blog, it then runs `publication(host:)` or `publication(id:)`. The token is sent in the `Authorization` header (Hashnode accepts it with or without a `Bearer ` prefix).

Hashnode's editor can't be prefilled from a link, which is why hand-off copies the article instead.

## What gets posted

NEFORUM sends the `publishPost(input: PublishPostInput!)` mutation:

| NEFORUM | Hashnode field | Notes |
|---|---|---|
| Title (**required**) | `title` | If there's no title, NEFORUM uses the first line of your text. |
| Text | `contentMarkdown` | Markdown. A link you attach is added to the end. The whole request must stay under **100 KB**. |
| Tags | `tags: [{slug, name}]` | At most **15**. The slug is lower-case and hyphenated: `Web Dev` becomes `web-dev`. New tags are created automatically. |
| Images | Cover and inline images | See below. |

**Per-network options** (`extra`):

| Option | Hashnode field |
|---|---|
| `canonicalUrl` | `originalArticleURL`, the canonical link for an article that first appeared elsewhere |
| `subtitle` | `subtitle` |
| `slug` | `slug` |
| `disableComments: true` | `disableComments` |
| `coverImageUrl` | The cover, as an image URL you already host |
| `coverFromFirstImage: false` | Embeds every image in the article instead of using the first as the cover |

### Images

Each image is uploaded to Hashnode's CDN in three steps:

1. `createImageUploadURL` returns a `presignedPut` link.
2. NEFORUM PUTs the image bytes to that link.
3. `confirmImageUpload` checks the image.

Images can be up to **8 MB**. Any `image/*` type works except SVG. The first image becomes the cover. The others are added at the end of the article as `![alt](url)`.

The cover goes in the `coverImage` field of `PublishPostInput`. The older `coverImageOptions` object is no longer part of the schema; the API rejects it with `BAD_USER_INPUT`.

## Limits

- **Pro is required for API posting.** This is Hashnode's rule since May 2026, and NEFORUM can't work around it.
- **No server-side scheduling.** The current API has no mutation that schedules a post (`scheduledPost` is read-only). `publishedAt` back-dates a post; it doesn't schedule one. NEFORUM schedules on your device.
- **Endpoint.** Accounts and input that still name `https://gql.hashnode.com` are moved to `https://gql-beta.hashnode.com` automatically. If Hashnode moves the API again, enter the new address under **API endpoint (advanced)**.
- **No video upload.** Embed videos with a link in the text instead.

## Troubleshooting

| Hashnode error | What it means | What to do |
|---|---|---|
| `FORBIDDEN` with a message about Pro | Your blog is not on Pro | Upgrade the blog, or use hand-off. Trying again won't help. |
| `UNAUTHENTICATED` | The token was revoked or mistyped | Reconnect. |
| `BAD_USER_INPUT` / `GRAPHQL_VALIDATION_FAILED` | Something in the post was rejected | NEFORUM shows Hashnode's message. |
| `NOT_FOUND` | The blog is gone or the token can't see it | Reconnect and pick the blog again. |
| HTTP 301/302 | Hashnode moved its API address again | NEFORUM shows where it moved. Enter the new address under **API endpoint (advanced)**. |

Hashnode often returns these errors with HTTP 200. NEFORUM reads the `errors` list, not only the status code.

## Sources

- Hashnode API announcement (Pro requirement, 13 May 2026): https://hashnode.com/announcements/graphql-api
- Image upload change (`presignedPut`, `presignedPost` removed 7 September 2026): https://hashnode.com/changelog/2026-09-01-presigned-post-deprecated
- Hashnode GQL skill (official; production endpoint `gql-beta.hashnode.com`, `Bearer` optional): https://hashnode.com/blog/hashnode-gql-agent-skill and https://github.com/Hashnode/gql-skill/blob/main/skills/gql-api/SKILL.md
- Schema: https://github.com/Hashnode/gql-skill/blob/main/skills/gql-api/references/schema.graphql
- Auth: https://github.com/Hashnode/gql-skill/blob/main/skills/gql-api/references/auth-and-roles.md
- Errors and limits: https://github.com/Hashnode/gql-skill/blob/main/skills/gql-api/references/errors-and-limits.md
- Recipes (publish, image upload): https://github.com/Hashnode/gql-skill/blob/main/skills/gql-api/references/recipes.md
- Developer settings (tokens): https://hashnode.com/settings/developer
