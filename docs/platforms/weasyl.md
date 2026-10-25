# Weasyl setup guide

This guide adds Weasyl to NEFORUM. Each artwork post then opens Weasyl's visual submission form with your title, description and tags ready to copy, and you submit it.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **Weasyl**.
3. Optionally type a label, for example your Weasyl username.
4. Click **Add Weasyl**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your Weasyl account.
2. Add one image, a title, the description and at least 2 tags.
3. Set the rating.
4. Click the **Post to** button. NEFORUM opens <https://www.weasyl.com/submit/visual> and puts the description on the clipboard.
5. Sign in to Weasyl if asked.
6. In the hand-off window, click **Save media to Downloads** and choose the image as the submission file. A thumbnail is optional.
7. Copy the **Title** into the title field.
8. Choose the category, and a folder if you use one.
9. Set the rating:
   - General: **General**
   - Mature: **Mature**
   - Adult: **Explicit**
10. Paste the description.
11. Copy the **Tags** into the tags field. They are separated by spaces.
12. Submit the form. Weasyl may ask you to crop the thumbnail next.
13. Back in NEFORUM, click **I posted it**.

## How it works

Weasyl's official API can only read (with an API key or OAuth2); it has no upload endpoint. NEFORUM therefore prepares the submission and you submit it.

- The post's **title** becomes the submission title. Without one, NEFORUM uses the first line of the text.
- The post's text is the description, and its tags are the submission tags.
- **Rating:** Weasyl takes General, Mature and Explicit work. NEFORUM's Adult rating is Weasyl's Explicit.
- **Ask not to train AI:** the form has no such option, so this changes nothing here.
- Weasyl only receives artwork. A post without **Artwork** turned on, or without an image, shows an error and is not handed off.
- One image per submission: NEFORUM hands over the first image.
- The form also has options to request critique and to send no notification.
- Weasyl has no phone app; use its website.
- With the NEFORUM browser extension on a computer, the extension adds the file, title, description and tags where it finds the fields. You do the remaining steps.

## Limits

- JPEG, PNG or GIF, up to 50 MB.
- At least 2 tags. NEFORUM warns when there are fewer.

## Sources

- Weasyl API: https://projects.weasyl.com/weasylapi/
- Weasyl FAQ (file limits): https://www.weasyl.com/help/faq
- PostyBirb Weasyl code (form fields): https://raw.githubusercontent.com/mvdicarlo/postybirb-plus/master/electron-app/src/server/websites/weasyl/weasyl.service.ts
