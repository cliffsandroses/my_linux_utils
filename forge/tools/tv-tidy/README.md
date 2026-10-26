# tv-tidy

- **I want to:** an LG TV without ads, sponsored rows and slow bloat.
- **Where I'll use it:** the TV, from the laptop on the same Wi-Fi.
- **Done when:** the home screen is clean and fast, and every change can be undone.
- **Must never:** brick the TV, or leave a root exploit open.

## The TV
LG, webOS (vault: Homelab/README.md). The exact model and webOS version decide what's possible: Settings →
General → About This TV (or "Support" → TV Information) shows both; the sticker on the back has the model too.

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
