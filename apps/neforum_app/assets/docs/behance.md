# Behance setup guide

This guide adds Behance to NEFORUM. Each artwork post then opens Behance's project editor with your title, description and tags ready to copy, and you publish the project.

## Steps

1. In NEFORUM, open **Accounts** and click **Add account**.
2. Click **Art and portfolios** and choose **Behance**.
3. Optionally type a label, for example your Behance username.
4. Click **Add Behance**.

## Steps: posting artwork

1. In the composer, turn on **Artwork** under **Post to** and select your Behance account.
2. Add your images, a title, the description and up to 10 tags.
3. Set the rating, **Made with AI** and **Ask not to train AI**.
4. Click the **Post to** button. NEFORUM opens <https://www.behance.net/portfolio/editor> and puts the description on the clipboard.
5. Sign in with your Adobe account if Behance asks.
6. In the hand-off window, click **Save media to Downloads**.
7. Add the images to the project canvas with **Image** in the **Add Content** panel.
8. Click **Continue** and set the **Cover Image**.
   - Pick one of the project's images, at least 808 x 632 pixels and not a GIF.
   - Crop it with the slider and click **Crop & Continue**.
9. Copy the **Title** into **Project Title**.
10. Choose at least one **Creative Field**.
11. Copy the **Tags** into **Project Tags**.
12. If the work was made with AI, list the AI tools under **Tools Used**.
13. If the rating is Mature or Adult, tick **This project contains adult content**.
14. Open **Co-owners, Credits, and More** and paste the description.
15. Click **Publish**.
16. Back in NEFORUM, click **I posted it**.

## How it works

Behance has no posting API that NEFORUM can use. The old Behance API worked with per-app keys, and Behance no longer issues them: the developer pages at behance.net/dev are gone. That API never had a way to create or publish a project either. "Publish to Behance" inside Adobe's own apps is a private Adobe feature. NEFORUM therefore prepares the project and you press Publish.

- The post's **title** becomes the project title. Without one, NEFORUM uses the first line of the text.
- The post's text is the project description, and its tags are the project tags (NEFORUM hands over the first 10).
- **Rating:** Behance allows adult content when the project is flagged. For Mature and Adult work, NEFORUM reminds you to tick the adult content box.
- **Made with AI:** Behance allows AI-assisted work and asks you to list the AI tools under Tools Used.
- **Ask not to train AI:** Behance has no such option, so this changes nothing here.
- Behance only receives artwork. A post without **Artwork** turned on, or without an image, shows an error and is not handed off.
- Behance does not save projects on its own. Publish, or click **Save** for a draft, before you leave the editor.
- With the NEFORUM browser extension on a computer, the extension adds the files, title, description and tags where it finds the fields. You do the remaining steps.
- On a phone, NEFORUM opens the editor in your browser. Behance's apps document posting a work in progress, not a full project.

## Limits

- Images: JPEG (recommended), PNG or GIF, up to 50 MB (10 MB or less recommended) and 32 megapixels. PDF, PSD, TIFF and DOC files are not accepted as project images. CMYK images are converted to RGB.
- Images are shown 1400 pixels wide in the project and up to 2800 pixels in the lightbox.
- Cover: at least 808 x 632 pixels, shown at 202 x 158. A GIF cannot be the cover.
- Video: MPEG, MPG, ASF, AVI, FLV, M4V, MOV, MP4, 3GP, 3G2, MJ2 or WMV, each under 1 GB, shown at most 1280 pixels wide (embed YouTube or Vimeo for full width).
- Behance sets no limit on images per project. NEFORUM hands over up to 100.
- Up to 10 tags. At least one creative field. A cover, a title and a creative field are required to publish.

## Sources

- Create and publish a project: https://help.behance.net/hc/en-us/articles/204483684-Guide-Create-Publish-A-Project
- Required fields: https://help.behance.net/hc/en-us/articles/204483524-FAQ-What-fields-are-required-before-publishing
- Project tags: https://help.behance.net/hc/en-us/articles/204483954-Guide-Project-Tags
- Creative fields: https://help.behance.net/hc/en-us/articles/204483944-Guide-Creative-Fields
- Image formatting: https://help.behance.net/hc/en-us/articles/204484614-Guide-Formatting-Images-For-Display-On-Behance
- Audio and video formatting: https://help.behance.net/hc/en-us/articles/204484624-Guide-Formatting-Audio-Video-For-Behance
- Supported file types: https://help.behance.net/hc/en-us/articles/9510593419035-FAQ-What-files-types-are-supported
- Adult content: https://help.behance.net/hc/en-us/articles/204485024-Guide-Adult-Content-on-Behance
- Work in progress from the iOS app: https://help.behance.net/hc/en-us/articles/360005904314-Guide-Sharing-a-Work-in-Progress-from-the-Behance-iOS-app
- Behance API status (Adobe community): https://experienceleaguecommunities.adobe.com/t5/adobe-developer-questions/where-can-i-find-behance-api/td-p/408771
