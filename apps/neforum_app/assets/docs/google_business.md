# Google Business Profile setup guide

This guide adds Google Business Profile (formerly Google My Business) to NEFORUM by hand-off: NEFORUM copies your text and opens Google, and you add the update there. There is nothing to set up, no Google Cloud project and no sign-in.

## Steps

1. In NEFORUM, add an account and choose **Google Business Profile**.
2. Optionally type a label, for example the business name.
   - If you manage several businesses, add one account per business.
3. Tap **Add Google Business Profile**.

## Steps: When you publish

1. Publish the post in NEFORUM. It copies your text to the clipboard and opens <https://business.google.com/>.
   - On a phone it opens **Google Maps**: open your Business Profile there.
2. Choose **Posts > Add post**.
3. Pick **Update**. For an offer or event, pick that type instead.
4. Paste your text.
5. Add your photo or video.
6. If your post has a link, NEFORUM shows it: under **Button**, pick **Learn more** and paste the link there.
7. Select **Post**.
   - Google's form can also schedule the post (**Schedule this post**); NEFORUM does not control that.

## How it works

| Tier | What you need | Cost | Result |
|---|---|---|---|
| **Hand-off** (only tier) | Owner or manager of a **verified** Business Profile. A browser (computer) or the Google Maps app (phone) | Free | NEFORUM copies your text and opens Google. You choose **Posts > Add post > Update**, paste, add a photo and select **Post**. |

Status as of October 2026.

### Why there is no automatic posting

Google does have an API for this (Business Profile API v4, `localPosts.create`), but in practice nobody can use it from NEFORUM:

- Every Google Cloud project starts with a quota of **0 requests per minute**. The API does nothing until Google approves an *Application for Basic API Access*.
- To apply, you must "manage a Google Business Profile that is verified and active for 60+ days", have a website for the business, and apply with an email listed as an owner or manager.
- An approved project belongs to whoever applied. A free, open-source app cannot share one approved project between all its users, so every user would need their own approved project.
- Even then, the API takes photos only from a public URL and cannot create Product posts.

## Limits

- Text: about **1,500 characters**. This figure is widely cited, but Google's help pages do not state it.
- One photo **or** one video per update.
- Photos: JPG or PNG, 10 KB to 5 MB, at least 250 x 250 px (720 x 720 recommended).
- Videos: up to 30 seconds and 75 MB, 720p or higher.
- Google "may remove posts with unverified contact information". Use the **Call now** button instead of typing a phone number. NEFORUM warns when your text seems to contain one.
- Posts stay **Pending** until your profile is verified.
- Event and offer titles, dates and coupon codes are entered in Google's form. NEFORUM has no fields for them.
- Google has no link that opens a prefilled update, so you always paste the text yourself.
- The old Google My Business app (`com.google.android.apps.vega`) was shut down in 2022. On phones, NEFORUM opens Google Maps instead.

## Sources

- Business Profile API prerequisites (0 QPM until approved, eligibility): https://developers.google.com/my-business/content/prereqs
- Posts data and `localPosts.create`: https://developers.google.com/my-business/content/posts-data and https://developers.google.com/my-business/reference/rest/v4/accounts.locations.localPosts/create
- Create posts on your Business Profile: https://support.google.com/business/answer/7342169
- How to make a post & track its status (Posts > Add post, Button, Schedule this post; checked 2026-10-11): https://support.google.com/business/answer/7390603
- Posts content policy (contact information): https://support.google.com/business/answer/7213077
- Photo and video guidelines: https://support.google.com/business/answer/6103862
- Managing your profile in Google Maps: https://support.google.com/business/answer/9867764
