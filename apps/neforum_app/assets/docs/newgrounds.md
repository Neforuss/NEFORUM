# Newgrounds setup guide

This guide adds Newgrounds to NEFORUM. Each artwork post then opens Newgrounds' new art project form with your title, description and tags ready to copy, and you publish it.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **Newgrounds**.
3. Optionally type a label, for example your Newgrounds username.
4. Click **Add Newgrounds**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your Newgrounds account.
2. Add your images, a title, the description and up to 12 tags.
3. Set the rating and **Made with AI**.
4. Click the **Post to** button. NEFORUM opens <https://www.newgrounds.com/projects/art/new> and puts the description on the clipboard.
5. Sign in to Newgrounds if asked.
6. In the hand-off window, click **Save media to Downloads** and add the images to the project.
7. Crop the thumbnail.
8. Copy the **Title** into the title field and paste the description.
9. Copy the **Tags** into the tags field.
10. Choose the category: 3D Art, Comic, Fine Art, Illustration, Pixel Art or Other.
11. Answer the rating questions (nudity, violence, explicit text, adult themes). Newgrounds rates the work E, T, M or A from your answers.
12. Tick **finished piece** to include the work in the Art Portal (optional).
13. Click **Publish** and agree to the terms.
14. Back in NEFORUM, click **I posted it**.

## How it works

Newgrounds' only API, Newgrounds.io, covers game medals, scoreboards and cloud saves. It has nothing for art. NEFORUM therefore prepares the project and you press Publish.

- The post's **title** becomes the project title. Without one, NEFORUM uses the first line of the text.
- The post's text is the description, and its tags are the project tags (NEFORUM hands over the first 12).
- **Rating:** Newgrounds allows adult work. It sets the rating (E, T, M or A) from your answers to the rating questions; explicit work is rated A.
- **Made with AI:** the Art Portal does not accept AI-generated art, apart from minor AI help that you disclose. NEFORUM shows a warning for AI-made artwork.
- **Ask not to train AI:** the form has no such option, so this changes nothing here.
- Newgrounds only receives artwork. A post without **Artwork** turned on, or without an image, shows an error and is not handed off.
- The form saves each field as you go, so fill it in from top to bottom.
- Art reaches the Art Portal only once you have been scouted.
- The form also has Creative Commons options and a way to opt out of awards.
- Newgrounds has no phone app for uploads; use its website.
- With the NEFORUM browser extension on a computer, the extension adds the files, title, description and tags where it finds the fields. You do the remaining steps.

## Limits

- GIF, JPEG, PNG or WebP, up to 150 MB per image (Newgrounds community wiki; the PostyBirb cross-poster uses 40 MB).
- Several images per project. NEFORUM hands over up to 100.
- The description can hold up to 10 inline images and 3 embeds.
- Up to 12 tags.

## Sources

- Art Portal (community wiki): https://newgrounds.wiki.gg/wiki/Art_Portal
- Newgrounds.io: https://www.newgrounds.com/wiki/creator-resources/newgrounds-apis/newgrounds-io
- PostyBirb Newgrounds code (form fields): https://raw.githubusercontent.com/mvdicarlo/postybirb-plus/master/electron-app/src/server/websites/newgrounds/newgrounds.service.ts
