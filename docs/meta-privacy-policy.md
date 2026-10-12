# A privacy policy URL for your Meta app

Last checked: 11 October 2026, on Meta's App Dashboard.

NEFORUM posts to Facebook Pages, Instagram and Threads through a Meta app that you create yourself. Meta's App modes page says: "Any data generated while an app is in Development mode, such as test posts, can only be seen by role users." To let everyone see your posts, you **Publish** the app, and the Publish page asks for a **Privacy policy URL**. In October 2026 that was the only required item; a data deletion URL, an app icon and a category were optional.

You can do either of these:

- **Option A:** enter NEFORUM's own privacy policy. Nothing to write or host.
- **Option B:** publish a short policy of your own, from the template below.

## Option A: use NEFORUM's privacy policy

On the Publish page (or **App settings > Basic**), enter:

| Field | Address |
|---|---|
| **Privacy policy URL** | `https://neforus.com/neforum/privacy/` |
| **Data deletion instructions URL** (optional) | `https://neforus.com/neforum/privacy/#data-deletion` |

That page is NEFORUM's policy, written by Neforus, who makes NEFORUM. It covers the Meta apps people create to post with NEFORUM. It says:

- NEFORUM has no server and collects nothing.
- Your accounts, tokens and posts stay on your device.
- Which Facebook, Instagram and Threads permissions NEFORUM uses, and what for.
- How to delete your data and remove the app's access.

It fits when you use the app **only with NEFORUM** and don't add other permissions or connect it to another service. Keep in mind:

- Meta makes every app's developer responsible for the app's privacy policy. Pointing to NEFORUM's page is your decision; Meta has not confirmed that a shared policy is fine.
- The contact address on that page belongs to Neforus. Questions people send there about your app reach Neforus, not you.

## Option B: publish your own policy

Any public page that opens without signing in will do, for example:

- a page on your own website;
- a free **GitHub Pages** site: a public repository with an `index.md` file, then **Settings > Pages > Deploy from a branch**;
- a free **Google Sites** page.

Copy the template, replace everything in [square brackets], delete the permission lines you don't use and publish the page. Enter its address as the **Privacy policy URL**. For the optional **Data deletion instructions URL**, use the same address (or its "Deleting your data" section, if your host links to headings).

```
# Privacy policy for [app name]

Last updated: [date]

[app name] is a Meta app that I, [your name], use to publish my own posts to
[my Facebook Page / my Instagram account / my Threads profile] with NEFORUM,
a free and open-source app that runs on my own devices.
Contact: [email address]

## What is collected

Nothing is collected by me or sent to me. The app has no server, no
analytics and no ads.

## What stays on my device

NEFORUM keeps the accounts I connect, their access tokens (in the system's
secure storage) and my posts on the device where I use it.

## Permissions

The app asks Meta only for what it needs to publish my posts:

- Facebook Pages: pages_show_list, pages_read_engagement,
  pages_manage_posts, business_management
- Instagram: instagram_business_basic, instagram_business_content_publish
- Threads: threads_basic, threads_content_publish

Data received from Meta is used only to publish my posts. It is never
sold, shared or used for advertising.

## Deleting your data

No data about anyone is kept on a server, so there is nothing to request.
To remove the app's access:

- Facebook: Settings & privacy > Settings > Business integrations
  (or Apps and websites), then remove [app name].
- Instagram: Settings > Apps and websites, then remove [app name].
- Threads: Settings > Account > Website permissions, then remove [app name].

Posts already published stay on each network until they are deleted there.
For help, write to [email address].
```

## Related

- [Facebook setup guide](platforms/facebook.md), step 5
- [Instagram setup guide](platforms/instagram.md)
- [Threads setup guide](platforms/threads.md)
