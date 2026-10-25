# Itaku setup guide

This guide adds Itaku to NEFORUM. Each artwork post then opens Itaku's upload page with your title, description, tags and content warning ready to copy, and you submit it.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **Itaku**.
3. Optionally type a label, for example your Itaku username.
4. Click **Add Itaku**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your Itaku account.
2. Add your images or one video, a title (up to 100 characters), the description and at least 5 tags.
3. Set the rating. Add a content warning (up to 30 characters) if the work needs one.
4. Click the **Post to** button. NEFORUM copies the description to the clipboard and opens the upload page:
   - one image: <https://itaku.ee/new/image>
   - several images: <https://itaku.ee/new/images>
   - a video: <https://itaku.ee/new/video>
5. Sign in to Itaku if asked.
6. In the hand-off window, click **Save media to Downloads** and drop the files into the drop zone.
7. Copy the **Title** into the title field and paste the description.
8. Copy the **Tags** into the tags field.
9. Copy the **Content warning**, if there is one, into the content warning field.
10. Set **Maturity rating**:
    - General: **SFW**
    - Mature: **Questionable**
    - Adult: **NSFW**
11. Choose gallery folders and the visibility if you want to.
12. Click **Submit** and confirm Itaku's maturity check.
13. Back in NEFORUM, click **I posted it**.

## How it works

Itaku has no public API documentation, developer program or way for users to get a token. Its web app talks to an internal API with the browser's own sign-in, which is not offered to other programs. NEFORUM therefore prepares the upload and you press Submit.

- The post's **title** becomes the title. Without one, NEFORUM uses the first line of the text.
- The post's text is the description, and its tags are the image's tags.
- **Rating:** Itaku allows NSFW work with a rating. Use Questionable for work that is not explicit but not quite SFW, including clothed fetish content.
- **Made with AI:** AI-generated images are not allowed in Itaku's feed or public gallery; AI may only serve as a reference for a full redraw. NEFORUM refuses AI-made artwork for Itaku.
- **Ask not to train AI:** Itaku's form has no such option, so this changes nothing here.
- Itaku only receives artwork. A post without **Artwork** turned on, or without an image or video, shows an error and is not handed off.
- **Add to feed** is on by default. Visibility can be public, profile only or unlisted.
- Itaku has no phone app; it is a website that works in a phone's browser.
- With the NEFORUM browser extension on a computer, the extension adds the files, title, description and tags where it finds the fields. You do the remaining steps.

## Limits

- Images: up to 10 MB each on free accounts. Supporters can upload more (30 MB at the first tier, up to 100 MB at the top tier).
- Several images: up to 100 per upload, 250 MB together (1 GB for supporters).
- Video: up to 250 MB (more for supporters).
- Title up to 100 characters, description up to 5,000, content warning up to 30.
- At least 5 tags per image.
- Itaku refuses uploads for a while when an account posts too many images in a short time.

## Troubleshooting

- **"Itaku needs at least 5 tags":** add tags in NEFORUM, or add them on Itaku before you submit.
- **Rate limited for posting too many images:** wait a while before the next upload.

## Sources

- Galleries help: https://itaku.ee/help/galleries
- Rules: https://itaku.ee/help/rules
- Supporter limits: https://itaku.ee/help/supporter
- About Itaku: https://itaku.ee/about
