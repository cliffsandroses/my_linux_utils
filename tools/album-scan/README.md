# album-scan

- **I want to:** digitise every printed photo in the family albums.
- **Where I'll use it:** phone (capture), homelab (processing), Immich (viewing): <https://photos.meldev.duckdns.org> if set, else Immich on the tailnet.
- **Done when:** every album is in Immich as its own album, each photo cropped straight, roughly dated, nothing lost.
- **Must never:** throw away an original or overwrite one.

## Existing FOSS checked
- **Open Camera** (F-Droid <https://f-droid.org/packages/net.sourceforge.opencamera/>): sharp, manual-focus captures; lock exposure.
- **Immich** (already running): albums, face grouping, and dates you can set in bulk.
- A flatbed scanner is better if one is around (SANE + Simple Scan, <https://gitlab.gnome.org/GNOME/simple-scan>).

## Plan
1. **Capture**: a phone stand over a black card under daylight, one album page per photo (4–6 prints at once), Open Camera with a 2 s timer. Glossy prints: tilt the light to kill glare.
2. **Split and straighten** (homelab script, OpenCV): find each print on the black card, cut it out, deskew, crop the border; keep the full page too.
3. **Name and date**: album name + page + position; you give a year per album (or page), it's written into EXIF so Immich sorts it.
4. **Upload**: straight into an Immich album per physical album (Immich CLI, <https://github.com/immich-app/immich>).
5. **Faces**: let Immich group them; you name the people once.

## Log
- 2026-10-26: task added (Moosa: "I need to digitise all the album photos").
