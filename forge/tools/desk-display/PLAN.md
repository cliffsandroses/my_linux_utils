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

## Everything else the ESP32 can do (complete plan, 2026-10-26)

The board stays on the desk and keeps the display job; these add parts (cheap, from Probots or SP Road) or reuse
the same board. Ordered by how useful they are to you.

| # | Project | Extra parts (≈₹) | What it gives you |
|---|---|---|---|
| 1 | **Desk display** (above) | jumpers ₹70 | homelab, downloads, playing, clips at a glance |
| 2 | **Approve button** | push button ₹10 | say yes to Soma requests from the desk (S25 still confirms) |
| 3 | **Room sensor** | BME280 ₹350 | temperature, humidity, pressure on the OLED and in Soma; "open the window" nudge |
| 4 | **Presence at the desk** | LD2410 mmWave ₹400 | automode knows you're at the desk even when the laptop is idle; screen sleeps when you leave |
| 5 | **Stream light** | WS2812 strip / ring ₹250 | glows red when you're live (automode stream mode), cyan when idle, amber when something needs you |
| 6 | **Monster can shelf lights** | WS2812 strip ₹250 | lights the can display (below) and follows the Prism hue |
| 7 | **Wake the PCs** | none | Wake-on-LAN for the laptop or homelab from the button or from Soma |
| 8 | **IR remote** | IR LED + receiver ₹60 | learn the TV/AC remotes; Soma buttons for power, volume, AC temperature |
| 9 | **Door / drawer sensor** | reed switch ₹40 | a notification when the door opens while you're streaming |
| 10 | **Plant or bottle reminder** | soil sensor ₹80 / load cell ₹250 | drink water / water the plant nudges |
| 11 | **Bluetooth tracker** | none | notices your phone or watch nearby (ESPHome bluetooth_proxy) to set "home/away" |
| 12 | **Macro pad** | 4 keys ₹100 | one-tap: stream mode, clip that, mute, lights |

Software for all of it stays ESPHome first (each is a few lines of YAML), with Soma as the screen and the control panel:
a Gadgets tile under Homelab listing each sensor and switch.

Order: 1 → 2 → 3 → 5 → 4. Parts for 1–5 together come to about ₹1,100.

## Getting the wires (2026-10-26)

Quick-commerce apps (Blinkit, Zepto, Instamart) don't stock breadboard jumpers. Fastest in Bangalore:
- **Probots** (Bangalore store, walk-in pickup, or Dunzo/Porter pickup after you confirm with them):
  [male-to-male 20 cm, 40 pcs](https://probots.co.in/male-to-male-jumper-wires-40-pcs-20-cm.html) (what you need: both boards sit in the breadboard, ≈₹69–89),
  [male-to-female 20 cm](https://probots.co.in/male-to-female-jumper-wires-40-pcs-20cm.html) (for sensors later),
  [140-piece breadboard kit](https://probots.co.in/breadboard-jumper-kit-140pcs-solderless-cable-wire-for-prototypi.html).
- **SP Road** (Bangalore's electronics market): any shop has jumper sets, BME280s and WS2812 strips the same day.

## Your room by remote: fan, lights, TV, AC, PS5 (2026-10-27)

"I want to be able to turn my fan off remotely and anything in my room." Everything below is switched from a Soma **Room** tile
(Homelab), from anywhere on the tailnet; all local, no vendor cloud. Software: ESPHome (<https://github.com/esphome/esphome>);
optionally Home Assistant (<https://github.com/home-assistant/core>) later.

| Thing | How | Parts (≈₹) |
|---|---|---|
| **Ceiling fan** (regular capacitor fan) | an ESP32 relay board behind the fan switch: one relay for on/off, two more switch the speed capacitors (steps 1–4). The wall switch keeps working. **An electrician fits it** (230 V). | 4-relay ESP32 board ₹650 + capacitors ₹200 |
| **Ceiling fan** (BLDC with a remote, e.g. Atomberg) | IR or RF: the ESP32 learns the fan remote and replays it (plan #8). No wiring. | IR LED + receiver ₹60 |
| **Lamp, LED strip, purifier, charger** | smart plugs that run Tasmota/ESPHome (ESP-based, 16 A, power metering) | ₹800 each |
| **Room light** | same relay board as the fan, second channel | – |
| **AC** | IR from the ESP32 (plan #8): on/off, temperature, mode | (same IR parts) |
| **TV** | already done: `ps5-play` talks to the LG over the network (on/off/state) | – |
| **PS5** | Chiaki wakes it; rest mode from the PS5 menu | – |
| **Laptop / homelab** | Wake-on-LAN (plan #7) | – |

Order: smart plug for the lamp first (no wiring, 10 minutes), then the IR blaster (AC, TV backup), then the fan board with an
electrician. Parts are on Deal Check: <https://soma.meldev.duckdns.org/artifact.html?id=deal-check>.
