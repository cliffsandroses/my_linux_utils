# desk-display: the ESP32 and OLED from the photo

- **I want to:** glance at the desk and know how the homelab is doing, without opening Soma.
- **Where I'll use it:** the desk, next to the laptop.
- **Done when:** the screen shows Soma's state (apps up/down, alerts, downloads, what's playing, clips waiting),
  updates by itself, and a button can say yes to a waiting request.
- **Must never:** hold a password, open anything to the internet, or approve a request without Soma's own check.

## What's in the photo

| Part | What it is | Notes |
|---|---|---|
| Dev board | ESP32-WROOM-32 DevKit, 38 pins, USB-C, BOOT and EN buttons | Wi-Fi + Bluetooth, 3.3 V logic |
| Screen | 128×64 OLED, I²C, 4 pins (VCC GND SCK SDA) | the larger 1.3" ones are usually SH1106, the 0.96" SSD1306; try SH1106 first |
| Breadboard | full size, power rails both sides | the ESP32 straddles the middle; the OLED's pins are still unconnected |

## Wiring (4 jumpers)

| OLED | ESP32 | Why |
|---|---|---|
| VCC | 3V3 | the screen runs at 3.3 V; don't use VIN (5 V) |
| GND | GND | |
| SCK (SCL) | D22 (GPIO22) | the ESP32's default I²C clock |
| SDA | D21 (GPIO21) | the default I²C data |

The BOOT button (GPIO0) doubles as a page button once the program is running; add a second push button
(GPIO27 to GND) for "approve".

## Software (all FOSS)

- **ESPHome** for the first version: one YAML file, flashed over USB once, then updated over Wi-Fi.
  <https://esphome.io> · source <https://github.com/esphome/esphome>. Its `http_request` component reads Soma, its
  `display` component draws on the SH1106/SSD1306.
- **PlatformIO + Arduino + U8g2** if it outgrows ESPHome (animations, custom fonts).
  <https://github.com/platformio/platformio-core> · <https://github.com/olikraus/u8g2>
- Flashing from the laptop: **esptool** <https://github.com/espressif/esptool> (ESPHome uses it underneath).
  Installing either needs your yes first.

## Soma side

A small read-only endpoint, `GET /api/desk`, answered only on the tailnet with a device token
(`~/.config/desk-display/token` on the laptop when flashing, never in the repo):

```json
{"apps":{"up":21,"down":0},"alerts":1,"downloads":[{"name":"…","pct":42}],"playing":"The Nanny S01E06",
 "clips_waiting":10,"docket_open":3}
```

The approve button doesn't approve by itself: it asks Soma to send the usual phone prompt ("Desk wants to approve
<request>"), so the fingerprint on the S25 still decides.

## Screens (BOOT cycles them)

1. **Home**: a tiny eclipse ring that is full when every app is up, with alerts as a number.
2. **Downloads**: up to three bars with names.
3. **Playing**: what Jellyfin is playing and who.
4. **Clips**: how many wait in the Clip studio.
5. **Clock**: when nothing needs you, a dim clock (OLEDs burn in: it shifts a few pixels every minute and dims at night).

## Steps

1. Wire the four jumpers above; flash ESPHome's "hello" and see text on the screen. (30 min)
2. Add `/api/desk` to Soma (tailnet only, token). (Claude)
3. ESPHome config: Wi-Fi, poll every 30 s, the five screens, BOOT to switch. (Claude writes, you flash once)
4. Approve button via Soma's phone prompt. (Claude)
5. A case: a 3D-printed stand or a small box, later.

## Later

A BME280 (temperature, humidity, pressure; I²C, same two pins) makes it a room sensor, shown in Soma too.
