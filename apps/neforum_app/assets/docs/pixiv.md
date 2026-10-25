# pixiv setup guide

This guide adds pixiv to NEFORUM. Each artwork post then opens pixiv's illustration upload page, or goes to the pixiv app on your phone, with your title, caption and tags ready to copy, and you post it.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **pixiv**.
3. Optionally type a label, for example your pixiv name.
4. Click **Add pixiv**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your pixiv account.
2. Add your images (in page order), a title, the caption and up to 10 tags.
3. Set the rating and **Made with AI**.
4. Click the **Post to** button. NEFORUM copies the caption to the clipboard.
5. On a phone, pick **pixiv** in the share sheet. On a computer, NEFORUM opens <https://www.pixiv.net/illustration/create>; sign in if asked.
6. On a computer, click **Save media to Downloads** in the hand-off window and pick the images in pixiv's file picker. Drag the thumbnails to set the page order.
7. Copy the **Title** into **Title**.
8. Paste the caption into **Caption**.
9. Copy the **Tags** into **Tags**.
10. Set **Age restriction**:
    - General: **All ages**.
    - Mature: **All ages**, and tick the box for slightly sexual content. Choose **R-18** if pixiv's rules call for it.
    - Adult: **R-18** (**R-18G** for grotesque content).
11. Set **AI-generated** to **Yes** if the work was made with AI, otherwise **No**.
12. Click **Post**.
13. Back in NEFORUM, click **I posted it**.

## How it works

pixiv publishes no developer program, registration or documentation. Its only API is the private one of its own app, which some community libraries reverse-engineer. pixiv's terms (Article 14) forbid loads beyond normal use, mechanically performing large numbers of actions in a short time, and posting the same work through several accounts. NEFORUM therefore prepares the upload and you press Post.

- The post's **title** becomes the work's title. Without one, NEFORUM uses the first line of the text.
- The post's text is the caption, and its tags are the work's tags (NEFORUM hands over the first 10).
- **Rating:** pixiv's age restrictions are All ages, R-18 and R-18G, chosen by you. Since November 2024 all-ages work has a checkbox for slightly sexual content.
- **Made with AI:** pixiv asks you to mark work as AI-generated when AI made all or most of it.
- **Ask not to train AI:** pixiv's form has no such option, so this changes nothing here.
- pixiv only receives artwork. A post without **Artwork** turned on, or without an image, shows an error and is not handed off.
- Post only your own work, from one account.
- For manga, use <https://www.pixiv.net/manga/create> instead. Ugoira (animation) uses <https://www.pixiv.net/ugoira/create>.
- In the pixiv app: **My Page** > **Post a work** > **Illustration** or **Manga**, then tags, age restriction and **Post**.
- With the NEFORUM browser extension on a computer, the extension adds the files, title, caption and tags where it finds the fields. You do the remaining steps.

## Limits

- JPEG, PNG or GIF. Animated GIFs are not accepted: pixiv uses Ugoira for animation.
- Up to 32 MB per image and 200 MB per post. NEFORUM shows an error above 200 MB.
- pixiv states no limit on images per post. NEFORUM hands over up to 100.
- Recommended manga page size: about 1700 x 2400 pixels.
- Tags: up to 10 per work, 30 characters each (figures from pixiv Encyclopedia).

## Sources

- Posting illustrations: https://www.pixiv.help/hc/en-us/articles/235584588-How-can-I-post-illustrations-on-pixiv
- Posting manga: https://help.pixiv.digital/hc/en-us/articles/235583948-How-do-I-post-manga-to-pixiv-
- File size limits: https://www.pixiv.help/hc/en-us/articles/235645687-Are-there-any-limits-on-image-file-size
- Recommended manga size: https://www.pixiv.help/hc/en-us/articles/900002618203-What-is-the-recommended-size-for-manga-works
- AI-generated option: https://www.pixiv.help/hc/en-us/articles/11866194231577-What-is-the-AI-generated-option-in-my-work-settings
- Terms of use: https://policies.pixiv.net/en.html
- Tags (pixiv Encyclopedia): https://dic.pixiv.net/en/a/Tag
- pixiv app: https://apps.apple.com/app/id337248563
