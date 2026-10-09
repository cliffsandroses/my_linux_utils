# Restore my PC

How to rebuild my machine from nothing: on Omarchy, any other Linux distro, or Windows.
Part 0 is what keeps a restore possible. Do it **now** and again every month. Parts 1–3
bring a new machine back.

Placeholders: `<homelab-vm>` is the homelab VM's tailnet or LAN address, and `<date>` is a
backup's date stamp.

---

## 0. Keep it restorable (on the current laptop)

### Where everything lives

| What | Where the copy lives | How it gets there |
|---|---|---|
| `~/Projects`, `~/Axon`, `~/Backups`, `~/EC01`, `~/Hera` | Homelab VM | Syncthing, continuous |
| This repo | GitHub + VM | git push, and Syncthing through `~/Projects` |
| Game saves | `~/Backups/game-saves` → VM | Ludusavi, run by `pc-backup` |
| Package lists | `~/Backups/pc/` → VM | `pc-backup` |
| **All of `~`**: settings, keys, documents, versioned | VM `/mnt/data/kopia-laptop` (encrypted) | **Kopia**, nightly via `pc-backup.timer` |

`~/.kopiaignore` lists what Kopia skips: Trash, caches, Downloads, games, `homelab-offsite`,
and anything that can be downloaded again.

**Two things to keep in your password manager**, because nothing can be restored without them:
- the **Kopia repository password**
- the VM login (`moosa` on the VM)

### How the nightly backup works
`pc-backup/pc-backup.sh` writes the package lists, runs `ludusavi backup`, then runs
`kopia snapshot create ~`. `pc-backup.timer` runs it at 02:30, or at the next boot if the
laptop was off then. A failed run shows up as a failed unit, which `laptop-health`
reports to the phone.

```bash
systemctl --user start pc-backup.service    # back up now
journalctl --user -u pc-backup -n 30        # what the last run did
kopia snapshot list ~                       # every version that exists
```

### Set up once (already done on the current laptop)
```bash
# Kopia: Arch `yay -S kopia-ui-bin`, then put the CLI on PATH
ln -s /opt/KopiaUI/resources/server/kopia ~/.local/bin/kopia
# A key that can only do SFTP on the VM, so backups run with nobody at the keyboard
ssh-keygen -t ed25519 -N "" -C kopia-backup -f ~/.ssh/kopia_backup
echo "restrict,command=\"/usr/lib/openssh/sftp-server\" $(cat ~/.ssh/kopia_backup.pub)" \
  | ssh moosa@<homelab-vm> 'cat >> ~/.ssh/authorized_keys'
kopia repository create sftp --host=<homelab-vm> --username=moosa \
  --path=/mnt/data/kopia-laptop --external --ssh-command=ssh \
  --ssh-args="-i $HOME/.ssh/kopia_backup -o BatchMode=yes"
kopia policy set --global --compression=zstd
# The timer
systemctl --user link ~/Projects/my_linux_utils/pc-backup/pc-backup.{service,timer}
systemctl --user enable --now pc-backup.timer
```

---

## 1. New Linux install (Omarchy, Arch, Fedora, Ubuntu/Debian…)

### 1.1 Install the OS
- Omarchy: boot the Omarchy ISO and install. Any other distro: its normal installer.
- Create the user **`moosa`**. Paths in the backups assume `/home/moosa`.

### 1.2 The three things needed to reach the backups

| | Arch / Omarchy | Fedora | Ubuntu / Debian |
|---|---|---|---|
| git, Syncthing | `sudo pacman -S --needed git syncthing` | `sudo dnf install git syncthing` | `sudo apt install git syncthing` |
| Tailscale | `sudo pacman -S tailscale` | `curl -fsSL https://tailscale.com/install.sh \| sh` | same as Fedora |

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up                       # Headscale: add --login-server <headscale URL>
systemctl --user enable --now syncthing
```

### 1.3 Get the synced folders back
1. Open `http://localhost:8384` → **Actions → Show ID**. Copy the new device ID.
2. In the **VM's** Syncthing UI: **Add Remote Device** → paste the ID → share `Projects`,
   `Axon`, `Backups`, `EC01`, `Aedon`. Remove the old laptop device.
3. Back on the new machine, accept each folder at the **same path as before**:
   `~/Projects`, `~/Axon`, `~/Backups`, `~/EC01`, `~/Hera`.
4. Wait until every folder shows **Up to Date** before going on.

This repo is then in `~/Projects/my_linux_utils`. Without Syncthing:
`git clone https://github.com/cliffsandroses/my_linux_utils ~/Projects/my_linux_utils`

### 1.4 Base apps and drivers
```bash
cd ~/Projects/my_linux_utils && ./Linux_SetupScript.sh --dry-run   # look first
./Linux_SetupScript.sh                                               # then for real
```
It asks for the distro (Arch / Fedora / Debian) and the system type. On Fedora and
Debian some packages (Docker CE, Obsidian, WezTerm) need their vendor repo added first.
If one fails, install that one by hand and re-run.

### 1.5 Reinstall everything else
```bash
cd ~/Backups/pc
# Arch / Omarchy
sudo pacman -S --needed - < pkglist-native.txt
yay -S --needed - < pkglist-aur.txt
# Any distro
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
xargs -a flatpaks.txt flatpak install -y flathub
```
Not on Arch? Read `pkglist-*.txt` as a checklist and install the ones you want with
`dnf`/`apt`, or with Flatpak where the distro doesn't have them.

### 1.6 Everything in `~`: settings, keys, documents (Kopia)
Install Kopia: Arch `yay -S kopia-ui-bin` then
`ln -s /opt/KopiaUI/resources/server/kopia ~/.local/bin/kopia`. Other distros: the deb/rpm
repo or AppImage from kopia.io/docs/installation.

```bash
# The new machine gets its own backup key. This asks for the VM password once
ssh-keygen -t ed25519 -N "" -C kopia-backup -f ~/.ssh/kopia_backup
echo "restrict,command=\"/usr/lib/openssh/sftp-server\" $(cat ~/.ssh/kopia_backup.pub)" \
  | ssh moosa@<homelab-vm> 'cat >> ~/.ssh/authorized_keys'

# Connect (asks for the Kopia repository password)
kopia repository connect sftp --host=<homelab-vm> --username=moosa \
  --path=/mnt/data/kopia-laptop --external --ssh-command=ssh \
  --ssh-args="-i $HOME/.ssh/kopia_backup -o BatchMode=yes"

kopia snapshot list --all                  # pick the newest snapshot ID of /home/moosa
kopia snapshot restore <id> ~/restored     # everything, into a side folder
```
Move back what you want from `~/restored`: `.ssh`, `.gnupg`, `.config/<app>`, documents.
Omarchy → Omarchy: all of `.config` can go back. Any other desktop: leave out `.config/hypr`,
`.config/omarchy` and `.config/waybar`. Then:
```bash
chmod 700 ~/.ssh ~/.gnupg && chmod 600 ~/.ssh/id_*
```
Log out and back in so the desktop reloads its settings.

### 1.7 Games and saves
Install the launchers: Arch `sudo pacman -S steam lib32-vulkan-radeon` (enable `[multilib]`
first if it's off); anywhere `flatpak install flathub com.valvesoftware.Steam
org.heroicgameslauncher.hgl`. For Ludusavi: Arch `yay -S ludusavi-bin`, anywhere
`flatpak install flathub com.github.mtkennerly.ludusavi`.

1. Open Steam and Heroic once and log in. GOG in Heroic: turn on **Cloud Save Sync** per game.
2. Reinstall the games.
3. Restore the saves. If step 1.6 put back `~/.config/ludusavi`, Ludusavi already knows
   the paths:
   ```bash
   ludusavi restore --preview     # shows what it would write
   ludusavi restore --force
   ```
   Otherwise open Ludusavi → **Other** → Roots: add Steam `~/.local/share/Steam` and Heroic
   `~/.config/heroic`. Set Restore → path to `~/Backups/game-saves`.

### 1.8 My own services (systemd distros)
```bash
~/Projects/my_linux_utils/laptop-health/install.sh
systemctl --user link ~/Projects/my_linux_utils/pc-backup/pc-backup.{service,timer}
systemctl --user enable --now pc-backup.timer
```
Also copy `~/.kopiaignore` back from `~/restored`.

---

## 2. Windows

In PowerShell:
```powershell
winget install Git.Git Syncthing.Syncthing tailscale.tailscale Obsidian.Obsidian `
  Valve.Steam HeroicGamesLauncher.HeroicGamesLauncher mtkennerly.ludusavi
```
1. **Tailscale**: sign in from the tray icon. Headscale: `tailscale up --login-server <headscale URL>`.
2. **Syncthing**: open `http://localhost:8384`, then pair with the VM as in 1.3. Put the
   folders under `C:\Users\<you>\` with the same names (`Projects`, `Axon`, `Backups`…).
3. **Axon**: Obsidian → *Open folder as vault* → `Axon`.
4. **Files and keys**: `winget install Kopia.KopiaUI`. Open KopiaUI → *Connect to
   repository* → **SFTP**, host `<homelab-vm>`, user `moosa`, path `/mnt/data/kopia-laptop`.
   Authenticate with the VM password or a new key, then enter the repository password.
   Browse the newest snapshot and restore what you need. Put `.ssh` in
   `C:\Users\<you>\.ssh`, which is where Windows OpenSSH looks.
5. **Games**: log in to Steam and Heroic and reinstall. Steam Cloud and GOG cloud cover
   most saves. For the rest, open Ludusavi → **Restore** → path `Backups\game-saves`. Saves
   backed up from Proton or Wine on Linux may need **Other → Redirects** to map the Linux
   prefix path to `C:\Users\<you>`. Check with *Preview* first.
6. **Linux-only parts** (`Linux_SetupScript.sh`, dotfiles, `laptop-health`) don't apply.
   `wsl --install` gives a Linux shell for the scripts that don't need a desktop.

---

## 3. Done when

- [ ] Every Syncthing folder is **Up to Date**, and the laptop shows as connected on the VM
- [ ] `tailscale status` lists the homelab
- [ ] `ssh moosa@<homelab-vm>` logs in with the restored key
- [ ] A game launches and its save loads
- [ ] Linux: `systemctl --failed` and `systemctl --user --failed` are empty
- [ ] `systemctl --user start pc-backup.service` succeeds, so the next restore starts from this machine
