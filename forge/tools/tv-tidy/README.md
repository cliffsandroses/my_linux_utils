# tv-tidy

- **I want to:** an LG TV without ads, sponsored rows and slow bloat.
- **Where I'll use it:** the TV, from the laptop on the same Wi-Fi.
- **Done when:** the home screen is clean and fast, and every change can be undone.
- **Must never:** brick the TV, or leave a root exploit open.

## The TV
**LG OLED55C2PSC** (2022 C2, 55"), **webOS 26 / 11.2.0-3704**, Wi-Fi at **192.168.10.50** (MAC ac:b6:87:35:ad:4a), 5,810 hours.
Rooting: no known root for this firmware as of 2026-10-26, and LG blocks downgrades after webOS 26, so the plan is
settings + network blocking; homebrew only if webosbrew.org lists a root for 11.2 later.

## Plan (three levels; stop where you're happy)
1. **No hacking (10 min):** Settings → General → Additional Settings → Home Promotion **off**, Content Recommendation **off**;
   Settings → Support → Privacy & Terms: decline Viewing Information, Voice, Interest-Based Ads; Live Plus off.
2. **Block the ad servers on the network:** the homelab's DNS blocker (AdGuard Home, FOSS
   <https://github.com/AdguardTeam/AdGuardHome>) with an LG ad/telemetry list (e.g. `ngfts.lge.com`, `ad.lgappstv.com`,
   `lgtvsdp.com` ads hosts) for the TV's IP only.
3. **Homebrew** (FOSS: webOS Homebrew Channel <https://github.com/webosbrew/webos-homebrew-channel>): with the model and
   firmware, check <https://rootmy.tv> / <https://www.webosbrew.org> for a working root (it depends on the version). Without
   root, Developer Mode works but expires every ~50 hours. Then: an ad-free YouTube (youtube-webos, FOSS
   <https://github.com/webosbrew/youtube-webos>) and a launcher without promotions.

## Doing it on this TV (2026-10-26)
1. **Settings** (gear → All Settings): General → System → Additional Settings → Home Settings: **Home Promotion off**,
   **Content Recommendation off**; General → System → Additional Settings → Advertisement: **Limit ad tracking on**;
   Support → Privacy & Terms → User Agreements: untick **Viewing Information**, **Voice Information**, **Interest-Based
   Advertising**; General → System → Additional Settings → **Live Plus off**.
2. **Point the TV at the homelab's AdGuard**: Network → Wi-Fi → Advanced Wi-Fi Settings → Edit → DNS server
   **192.168.10.20** (today it asks the router, so AdGuard never sees it).
3. **Block LG's ad and tracking servers**: AdGuard (http://192.168.10.20:3000 or its Soma tile) → Filters → Custom
   filtering rules, paste:
   ```
   ! LG TV ads and tracking
   ||lgsmartad.com^
   ||ad.lgappstv.com^
   ||ngfts.lge.com^
   ||aic-ngfts.lge.com^
   ||lgtvonline.lge.com^
   ||smartclip.net^
   ||yumenetworks.com^
   ```
   (Claude tried to add these itself; its safety check blocked editing AdGuard's config.) If an app stops working,
   AdGuard's query log for 192.168.10.50 shows which rule to remove.
