# smithy

Moosa's machines and the tools made for them (renamed from my_linux_utils on 2026-10-26, when forge moved in).
Setup and rebuild scripts for the laptop and the homelab, and **forge/**: tools made when you want to use something
(how a tool gets made, the template, and every tool: `forge/README.md`).

Two setup scripts, both kept:

- `Linux_SetupScript.sh` — the current one (September 2026): flags, helpers, drivers, hardening.
- `Linux_SetupScript.overhaul.sh` — the February 2026 overhaul: menus, distro/CPU/VM detection, Docker, Bluetooth.

Rebuilding a whole machine? Start with RESTORE.md. Rebuilding the homelab VM? HOMELAB-REBUILD.md.

Also here:

- `arch/arch-apps.sh` — the app set for Arch + KDE when there is no saved package list.
- `arch/post-install.sh` — static LAN IP, Headscale join, Syncthing, search index, timers.
- `arch/fingerprint.sh` — enroll a finger; lock screen, sudo and KDE prompts accept it.
- `openclaw/` — OpenClaw on the laptop: `install.sh` brings back the CLI and the WhatsApp watchdog timer, and lists the steps that need you.
- `arch/ps5-remote-play.sh` — PS5 Remote Play: chiaki-ng, video decoding, DualSense, finds the PS5, firewall rule, backs up the pairing.
- `luks-header-backup.sh` — copy every LUKS header off the machine. Run before any disk work.
- `pc-backup/` — nightly package lists + Kopia snapshot of ~, and it checks the snapshot landed.
- `laptop-health/` — alerts the phone, including when the home backup or a LUKS header copy is missing.
- `syncthing/projects.stignore` — `~/Projects/.stignore`, which Syncthing never syncs.
- `profiles/moosa.env` — my settings for the homelab and the laptop (no secrets). Everything else reads it.
- `homelab/` — the homelab, scripted from that profile: `run.sh vm|pve <script> [--check]`. Order in HOMELAB-REBUILD.md.

Notes: 

Need to have dos2unix package before using the file
or unix will assume there is a character "/r" at the end of each readout


Stackoverflow: 
"Bash expects that end-of-line in a script is always and only a newline (\n) character, Unix-style, not a carriage return-newline combination (\r\n) like you normally see on Windows. 
Bash thinks the \r character is just an ordinary character at the end of the string. (Characters that follow a double quoted string are just concatenated onto the end.)
As Ignacio suggests, the solution is to fix your script to eliminate the \r characters. dos2unix is one way. Another would be to use tr -d '\r' < infile > outfile as a filter."
