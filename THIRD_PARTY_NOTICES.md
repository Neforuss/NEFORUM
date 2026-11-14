# Third-party notices

NEFORUM is free software under the GNU General Public License v3 ([LICENSE](LICENSE)). This file lists the data NEFORUM ships that others made. The app shows the same notices, with the licences of every package it is built from, under **Settings > About > Licenses**.

## Unicode data in the character panel

The Symbols and Text styles tabs, and the search words for emoji and symbols, are made from these files by `packages/neforum_core/tool/generate_character_catalog.dart`. The tool checks each file against the SHA-256 below before it uses it, and the generated files in `packages/neforum_core/assets/characters` record the same versions and hashes.

| File | Version | Source | SHA-256 |
|---|---|---|---|
| `Blocks.txt` | Unicode 18.0.0 | https://www.unicode.org/Public/18.0.0/ucd/Blocks.txt | `a58f8d322f3c5e254f9f97b1cbf76a454a7e02de6ac35619a5e4f27aaabfd553` |
| `UnicodeData.txt` | Unicode 18.0.0 | https://www.unicode.org/Public/18.0.0/ucd/UnicodeData.txt | `0736451de439ae7baf1425136617da495e09ee5afbe6e394374db7009ea08950` |
| `NamesList.txt` | Unicode 18.0.0 | https://www.unicode.org/Public/18.0.0/ucd/NamesList.txt | `e0732f7cb47a08ee2186c83a18a91ae277126e8099b53c432b4c3e32488dac9b` |
| `CP437.TXT` | 2.00 (1998-04-24) | https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/PC/CP437.TXT | `6bad4dabcdf5940227c7d81fab130dcb18a77850b5d79de28b5dc4e047b0aaac` |
| `CP1252.TXT` | 2.01 (1998-04-15) | https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT | `f607ae328b4dff5e9bfef725f5fff0ae23f38797f8a5b95998a0d2735c0e8fad` |
| `IBMGRAPH.TXT` | 1.0 | https://www.unicode.org/Public/MAPPINGS/VENDORS/MISC/IBMGRAPH.TXT | `5c8052b5a9c3852b1cb4b6a1b5d1591e8d26604e7ed457cbdc6f1cbe09463cf2` |
| CLDR English annotations | CLDR 49.0.0 | https://github.com/unicode-org/cldr-json (`cldr-annotations-full/annotations/en/annotations.json`) | `6b6b6e0e5f211bc31cf3fa39f385d80dea6cd19ee19bbc6db9071fce3ae5d360` |
| CLDR English derived annotations | CLDR 49.0.0 | https://github.com/unicode-org/cldr-json (`cldr-annotations-derived-full/annotationsDerived/en/annotations.json`) | `7aad034f689cb6553f8d7366bfee8c4ea2818c7776907bc5118aab575223dea3` |

`Blocks.txt`, `UnicodeData.txt` and `emoji-test.txt` (Unicode 18.0) are also kept in `packages/neforum_core/test/fixtures/unicode` for the tests.

These files are Copyright © 1991-2026 Unicode, Inc., used under the Unicode License v3:

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

## Written for NEFORUM

- **Kaomoji** (`packages/neforum_core/lib/src/characters/kaomoji.dart`): written for NEFORUM in 2026 from kaomoji in everyday use. No list, site or app was copied, scraped or reordered. The selection, groups, names and order are NEFORUM's, under the GPL v3.
- **Upside-down pairs and the symbol sets** (Popular, Hearts, Arrows and the others, in `tool/generate_character_catalog.dart`): NEFORUM's own choice, applied to the Unicode data above.
- textgenerator.net, alt-codes.net and copypastecharacter.com were used only as a checklist of features to offer. None of their lists is in NEFORUM.

## Other data

- **Emoji list:** the `unicode_emojis` package (MIT), built from Unicode's `emoji-test.txt`.
- **twitter-text conformance file** (tests only): Apache-2.0, kept with its licence in `packages/neforum_core/test/fixtures/twitter_text`.
- **Fonts:** Inter, Bricolage Grotesque, JetBrains Mono and TikTok Sans, under the SIL Open Font License, with their licence files in `apps/neforum_app/assets/fonts`.
