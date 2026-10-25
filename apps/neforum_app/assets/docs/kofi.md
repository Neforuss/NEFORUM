# Ko-fi setup guide

This guide adds Ko-fi to NEFORUM. Each artwork post then opens ko-fi.com with your title, text and tags ready to copy; you start an Image Post on your page and publish it.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **Ko-fi**.
3. Optionally type a label, for example your Ko-fi page name.
4. Click **Add Ko-fi**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your Ko-fi account.
2. Add up to 8 images, a title, the text and tags.
3. Click the **Post to** button. NEFORUM opens <https://ko-fi.com/> and puts the text on the clipboard.
4. Sign in to Ko-fi if asked.
5. Open your Ko-fi page and click **Create**, then **Add Something**, then **Image Post**.
6. In the hand-off window, click **Save media to Downloads** and add the images to the post.
7. Copy the **Title** into the title field.
8. Paste the text into the post body.
9. Copy the **Tags** into the tags field.
10. Choose the audience: everyone, monthly supporters or specific membership tiers.
11. Click **Publish**, or schedule the post or save it as a draft.
12. Back in NEFORUM, click **I posted it**.

## How it works

Ko-fi's API only reports payments ("Our API is currently limited to when a payment is made"); it cannot post. NEFORUM therefore prepares the image post and you publish it.

- The post's title, text and tags go to the image post's own fields.
- Images in an Image Post also appear in your Ko-fi gallery.
- **Rating:** Ko-fi is for a general audience, and posts can be limited to supporters or tiers. NEFORUM shows a warning for Adult artwork.
- **Ask not to train AI:** Ko-fi has no such option, so this changes nothing here.
- Ko-fi only receives artwork. A post without **Artwork** turned on, or without an image, shows an error and is not handed off.
- An official Ko-fi app could not be confirmed, so on a phone NEFORUM opens the website.

## Limits

- JPEG, PNG or GIF, up to 25 MB on free pages (60 MB with Ko-fi Gold). NEFORUM warns above 25 MB.
- Ko-fi publishes no image count. NEFORUM hands over up to 8, the gallery limit the PostyBirb cross-poster uses.

## Sources

- Ko-fi API and webhooks: https://help.ko-fi.com/hc/en-us/articles/360004162298-Does-Ko-fi-have-an-API-or-webhook
- Creating posts: https://help.ko-fi.com/hc/en-us/articles/360007638073-Creating-posts-Let-s-make-them-shine
- PostyBirb Ko-fi code (gallery fields): https://raw.githubusercontent.com/mvdicarlo/postybirb-plus/master/electron-app/src/server/websites/ko-fi/ko-fi.service.ts
