# tv-tidy

- **I want to:** a TV without ads, sponsored rows and slow bloat ("debloat it, as people are doing now").
- **Where I'll use it:** the TV, from the laptop on the same Wi-Fi.
- **Done when:** the home screen is clean and fast, and every change can be undone.
- **Must never:** uninstall system packages (disable only), touch anything whose job is unclear, or leave debugging on.

## Works on
Android TV / Google TV (Sony, TCL, Xiaomi, Hisense, OnePlus…). **Not** Samsung (Tizen), LG (webOS) or Roku: different systems.
Which TV is it? Settings → About shows the model. On the 2026-10-26 scan no TV answered on the home network (it was off,
or it's on another network).

## Plan
1. On the TV: Settings → Device Preferences → About → tap Build 7 times; Developer options → USB/network debugging on.
2. Laptop: `adb connect <tv-ip>` (android-tools, FOSS: <https://android.googlesource.com/platform/packages/modules/adb/>), accept the prompt on the TV.
3. List packages; disable ads/telemetry/bloat with `pm disable-user --user 0 <pkg>`, one batch at a time, each logged with its undo (`pm enable`) in `tv-tidy.log`.
4. Optional: a clean launcher, FLauncher (FOSS, <https://gitlab.com/flauncher/flauncher>), and SmartTube for ad-free YouTube (FOSS, <https://github.com/yuliskov/SmartTube>).
5. Turn debugging off at the end.

Background: [Android Authority on TV "vibe hacking"](https://www.androidauthority.com/android-tv-vibe-hacking-remove-ads-bloatware-3725338/), [It's FOSS](https://itsfoss.com/news/debloat-smart-tv/).
