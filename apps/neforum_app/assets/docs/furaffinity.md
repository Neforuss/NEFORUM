# Fur Affinity setup guide

This guide adds Fur Affinity to NEFORUM. Each artwork post then opens Fur Affinity's submission page with your title, description and keywords ready to copy, and you finalize the submission.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **Fur Affinity**.
3. Optionally type a label, for example your Fur Affinity username.
4. Click **Add Fur Affinity**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your Fur Affinity account.
2. Add one image, a title, the description and at least 3 keywords as tags.
3. Set the rating.
4. Click the **Post to** button. NEFORUM opens <https://www.furaffinity.net/submit/> and puts the description on the clipboard.
5. Sign in to Fur Affinity if asked.
6. Choose **Artwork** as the submission type.
7. In the hand-off window, click **Save media to Downloads** and upload the file. A thumbnail is optional.
8. Copy the **Title** into the title field and paste the description.
9. Copy the **Tags** into the keywords field. They are separated by spaces.
10. Set the rating to **General**, **Mature** or **Adult**, as in NEFORUM.
11. Choose the category, theme, species and gender, and a folder if you use one.
12. Click **Finalize**.
13. Back in NEFORUM, click **I posted it**.

## How it works

Fur Affinity has no API, and the site sits behind bot protection. NEFORUM therefore prepares the submission and you finalize it.

- The post's **title** becomes the submission title. Without one, NEFORUM uses the first line of the text.
- The post's text is the description, and its tags are the keywords.
- **Rating:** Fur Affinity takes General, Mature and Adult work. NEFORUM's rating maps straight onto it.
- **Made with AI:** Fur Affinity's upload policy (section 2.13) forbids AI and machine-learning generated content. NEFORUM refuses AI-made artwork for Fur Affinity.
- **Ask not to train AI:** the form has no such option, so this changes nothing here.
- Fur Affinity only receives artwork. A post without **Artwork** turned on, or without an image, shows an error and is not handed off.
- One file per submission: NEFORUM hands over the first image. Post other images as separate submissions.
- The form also offers scraps, disabling comments and a new folder.
- Fur Affinity has no phone app; use its website.
- With the NEFORUM browser extension on a computer, the extension adds the file, title, description and keywords where it finds the fields. You do the remaining steps.

## Limits

- About 10 MB per file (the figure the PostyBirb cross-poster uses; Fur Affinity shrinks large images). Fur Affinity's own limits could not be read.
- JPEG, PNG or GIF.
- Keywords: at least 3 of 3 or more characters, 500 characters in all (PostyBirb's checks). NEFORUM warns when there are fewer.

## Sources

- PostyBirb Fur Affinity code (form steps, limits): https://raw.githubusercontent.com/mvdicarlo/postybirb-plus/master/electron-app/src/server/websites/fur-affinity/fur-affinity.service.ts
- Art communities banning AI-generated images: https://waxy.org/2022/09/online-art-communities-begin-banning-ai-generated-images/
