# Install NEFORUM on iPhone and iPad

1. Download `neforum-ios-unsigned.ipa` from [neforus.com/neforum](https://neforus.com/neforum/) or the [latest release](https://github.com/Neforuss/NEFORUM/releases/latest).
2. Connect the iPhone or iPad to **Wi-Fi**. Sideloading apps can fail on mobile data (see below).
3. Sign and install the IPA with your own Apple ID or certificate in a sideloading app (Feather, AltStore, SideStore or Sideloadly), or build NEFORUM from source in Xcode.
4. Open NEFORUM from the Home Screen.

The IPA is not signed by Apple, so it needs one of these tools. Updates install the same way: when **Settings > Updates** says a new version is out, download the new IPA and install it over the old one, again on Wi-Fi.

## "192.0.0.2" or "not connected to the internet" on mobile data

If a sideloading app such as Feather shows 192.0.0.2 or "not connected to the internet" on mobile data, install over Wi-Fi.

Why this happens: in its **Semi Local** server mode, Feather starts a small web server on the phone. It then opens an install page at the phone's own IPv4 address, which it reads from the Wi-Fi interface (`en0`) or the mobile data interface (`pdp_ip0`).

- On Wi-Fi, that is a normal local address and the install works.
- Some carriers run IPv6-only networks with 464XLAT, a way of carrying older IPv4 traffic over them (T-Mobile US is one). They give the mobile data interface the address 192.0.0.2, from a block set aside for interfaces that are not routed ([RFC 7335](https://www.rfc-editor.org/rfc/rfc7335)). Safari cannot open a page at that address, so the sheet titled "192.0.0.2" says the iPhone is not connected to the internet.

The IPA itself is fine; the same file installs on Wi-Fi.

The sources, in Feather's code ([claration/feather](https://github.com/claration/feather), formerly khcrysalis/Feather, at commit `31ab6de`):

- [`ServerInstaller+TLS.swift`](https://github.com/claration/feather/blob/31ab6de455f2a6108f6830e343dee826310c03be/Feather/Backend/Server/ServerInstaller%2BTLS.swift): `sni()` uses `getLocalAddress()` in Semi Local mode, and `getLocalAddress()` takes the IPv4 address of `en0` or `pdp_ip0`.
- [`ServerInstaller+Compute.swift`](https://github.com/claration/feather/blob/31ab6de455f2a6108f6830e343dee826310c03be/Feather/Backend/Server/ServerInstaller%2BCompute.swift): the install page, the IPA and the install manifest are all served at that address.
- [`InstallPreviewView.swift`](https://github.com/claration/feather/blob/31ab6de455f2a6108f6830e343dee826310c03be/Feather/Views/Library/Install/InstallPreviewView.swift): Semi Local opens that install page in a Safari sheet.

If Wi-Fi is not available, Feather has a setting that may help: **Settings > Installation**, Server Type **Semi Local**, then turn on **Only use localhost address**. Feather then serves the install from 127.0.0.1, which does not depend on the mobile network. A Feather user reported that this makes installs over mobile data work ([Feather issue #78](https://github.com/claration/feather/issues/78)). NEFORUM has not tested it on every carrier.

Feather's other mode, **Fully Local**, relied on the backloop.dev certificate, which that service stopped issuing on 4 September 2026 ([Feather issue #722](https://github.com/claration/feather/issues/722), [backloop.dev](https://backloop.dev/)).

The problem comes from the way Feather installs apps and not from NEFORUM's IPA, so a lasting fix has to come from Feather.

## Other sideloading tools

- **AltStore** installs and refreshes apps through AltServer on your computer. If an install stalls, put the phone on the same Wi-Fi network as the computer.
- **SideStore** installs on the phone itself through its VPN app. If an install fails on mobile data, retry on Wi-Fi.
- **Sideloadly** and **Xcode** install from a computer (over USB, or Wi-Fi sync), so the phone's mobile data does not matter.

## Android is not affected

The Android `.apk` installs from the downloaded file with Android's own package installer. Nothing is served from the phone and no local web server is involved, so mobile data and Wi-Fi install it the same way.
