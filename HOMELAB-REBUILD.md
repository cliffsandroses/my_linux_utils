# Rebuild the homelab VM from its nightly backup

Written on 2026-10-21, the day VM 100 was rebuilt from nothing after a drive swap left its
disks empty. Every snag hit that day is in here with its fix, in the order you meet them.
The tested restore procedure behind it is `Axon/Homelab/restore-test.md`.

Placeholders: Proxmox is `192.168.10.13`, the VM `192.168.10.20`, the laptop `192.168.10.30`.

---

## 0. Before any disk work on the server (what went wrong)

- **Clonezilla does not copy Proxmox's `local-lvm` (LVM thin).** It recreated the thin volumes
  empty and reported success: every VM and container disk came out blank. To move a Proxmox
  boot disk, use `vzdump` of every guest to a disk that is not being moved, or `dd` the whole
  disk. Never trust a clone you have not booted.
- **Prove the copy before wiping the original.** Boot the copy and start each VM and CT. Look
  at `lvs`: a VM disk at `Data% 0.00` is empty. Only then reuse the old drive.
- **Clonezilla zeroes the first MiB of every old partition on the target.** If the target held
  a LUKS partition, that is its header and keys. Back headers up first: `luks-header-backup.sh`.
- **Installing Arch on a drive discards (TRIMs) all of it.** Nothing on that drive comes back
  afterwards, so whatever it held must already exist somewhere else, checked.
- **A backup that has never been read is not a backup.** On 2026-10-21 the laptop's Kopia
  repository turned out to hold zero snapshots. `laptop-health` now alerts on that.

## 1. Find what survived

The SATA data disk (`/mnt/data`, label `homelab-data`) and the USB media disk (`/mnt/media`)
are separate from the boot NVMe. Mount them read-only on Proxmox to look, and mark them
read-only at the block level while nothing else should write:

```bash
blockdev --setro /dev/sda /dev/sdb
mount -o ro,noload /dev/sda1 /mnt/rescue-sata     # noload: don't even replay the journal
```

What is there: `Backups/homelab/<date>` (nightly, 7 kept), `Backups/git-mirrors/` (every repo
from `~/Projects`, all refs), `immich/library` (photos + Immich's own DB dumps),
`Nextcloud-files/` (second copy), `Backups/homelab/pre-jellyfin-12.1-*` (Jellyfin DB, 16 Sept).
Check a set before trusting it: `cd <set> && sha256sum -c SHA256SUMS`. Copy the newest set
off the server before anything writes to that disk.

`~/homelab/backup/` is not inside the tarballs, but it is in `~/homelab`'s git history:
after restoring the home folder, `git -C ~/homelab checkout -- backup/`.

## 2. A new VM 100, without the installer

Use Debian's cloud image and cloud-init: no screen, no clicking, everything over SSH.

```bash
# on Proxmox
curl -fsSLO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
qm config 100 > /root/vm100.conf.before-rebuild          # keep the old disk lines
qm set 100 --delete scsi1,usb0,ide2                       # data disks off until the OS is ready
qemu-img convert -n -O raw debian-13-genericcloud-amd64.qcow2 /dev/pve/vm-100-disk-0
qm set 100 --ide2 local-lvm:cloudinit --ciuser moosa --sshkeys <pubkey-file> \
  --ipconfig0 ip=192.168.10.20/24,gw=192.168.10.1 --nameserver "1.1.1.1 8.8.8.8" \
  --boot order=scsi0 --agent enabled=1
qm start 100
```

Inside the VM:
- **Wait for first boot to finish** before apt: `sudo cloud-init status --wait || true`
  (it exits 2 for "done with warnings", which is fine).
- **Install `linux-image-amd64` and purge `linux-image-*cloud*`.** The cloud kernel has no USB
  storage driver, so the USB media disk never appears. Both share a version number and GRUB
  picks the cloud one, hence the purge, then `update-grub` and reboot.
- Packages: Docker CE (download.docker.com, `trixie`), Tailscale (pkgs.tailscale.com),
  `nfs-kernel-server syncthing cron rsync git jq sqlite3 unzip qemu-guest-agent`.
- `sudo timedatectl set-timezone Asia/Kolkata; sudo hostnamectl set-hostname homelab`.
- Port 53 for AdGuard: `DNSStubListener=no` in `/etc/systemd/resolved.conf.d/`, and point
  `/etc/resolv.conf` at `/run/systemd/resolve/resolv.conf`.

Reattach the data disks with the lines from `vm100.conf.before-rebuild` (on Proxmox first
`umount` and `blockdev --setrw`). fstab by UUID: `dfa90c1f-…` is `/mnt/data`, `96c969af-…` is
`/mnt/media`; the 210 GB `scsi2` becomes a fresh ext4 `homelab-nvme` at `/mnt/nvme`.

## 3. Put the files back

From the newest set (`B=/path/to/<set>`):

| Archive | Goes to |
|---|---|
| `homelab-config.tar.gz` | `tar -xzf - -C ~` → `~/homelab`, `~/Axon`, `~/.local/share/axon-dashboard`, `~/.config/systemd/user` |
| `arr-native-backups.tar.gz` | `tar -xzf - -C ~` (the arr apps' own backup zips) |
| `qbittorrent-config.tar.gz` | `/DATA/AppData/qbittorrent/config` (owner 1000) |
| `vol-<name>.tar.gz` | `docker volume create <name>`, then untar into it with an alpine container |
| `AdGuardHome.yaml` | `~/homelab/adguard/conf/` |
| `nextcloud-config.php` | `~/homelab/nextcloud/html/config/config.php` |

Then `git checkout -- backup/` in `~/homelab` (above), and rebuild `~/Projects` from the
mirrors: `git clone /mnt/data/Backups/git-mirrors/<repo>.git ~/Projects/<repo>`.

## 4. Start the apps: order and traps

1. **Caddy** (owns 80/443 and the `caddy_default` network Vaultwarden and Headscale join),
   **AdGuard**, **Vaultwarden**, **Headscale**. Caddy's and Home Assistant's compose files
   used to live in CasaOS's app folder; since 2026-10-21 they are in `~/homelab/caddy` and
   `~/homelab/homeassistant`.
2. **Immich.** The dumps in `library/backups/` are single-database dumps: load them into the
   `immich` database, **not** `postgres` (Immich's docs say `--dbname=postgres`, which is for
   `pg_dumpall` files). Apply the `search_path` fix from `restore-test.md`. **Raise the DB's
   memory cap for the load** (`docker update --memory 2g --memory-swap 2g immich_postgres`):
   at 512 MB it is OOM-killed during the load and again during the first-start map-data import.
   Check with `select count(*) from asset` and a sample of `originalPath` files on disk.
3. **Sonarr / Radarr / Prowlarr** from their own zips (`Backups/manual/*_03.15.*.zip`), not the
   raw `.db` files copied while they ran. **qBittorrent before the arr stack**: the arr compose
   joins `qbittorrent_default`.
4. **Nextcloud.** Create the `oc_admin` role (`dbuser`/`dbpassword` from `config.php`), make it
   owner of the database and `public`, and load the dump **as `oc_admin`**. Its old data dir
   `/mnt/nextcloud/data` lived on the VM's own disk: rebuild it from `/mnt/data/Nextcloud-files`
   plus `.ocdata`, owner 33. Then `occ upgrade` and `occ files:scan --all`.
5. **Home Assistant**, then everything else. **Profilarr** also needs 1 GB for its first start.
6. `loginctl enable-linger moosa`; the crontab and `/etc/cron.d/qbt-guard` are in
   `host-facts.txt` of the backup set. Don't enable timers whose app isn't back yet (Soma's
   build, Jellyfin's airing order): they fail every run.
7. Tailscale: delete the stale node in Headscale first, then join with a one-time key.
8. The VM needs a new SSH key in the laptop's `authorized_keys` for the nightly offsite push,
   and as a deploy key (write) on `cliffsandroses/axon-vault` for Axon's 03:00 push.

## 5. The Proxmox side

- **DNS fallback (CT 101):** `~/homelab/dns-fallback/create-dns-fallback.sh`, run as root on
  Proxmox. It refuses while a container named `dns-fallback` exists.
- **Jellyfin (CT 200):** follow the QuickSync runbook (Debian 12 LXC, privileged,
  `mount=nfs`, `/dev/dri`, same MAC `BC:24:11:C5:A7:65`, NFS mounts at `/movies /tv /music
  /shorts /downloads`). Its config comes from `pre-jellyfin-12.1-*/jellyfin-config.tar.gz`
  unpacked to `/config`. Give it **1.5 GB**, not 4 GB: it uses ~250 MB, and 4 GB overcommitted
  the 7.6 GB host. Set VAAPI in `/config/encoding.xml`.
- **Don't grow `local-lvm` until whatever was on the disk before is either copied or written off.**

## 6. Done when

- [ ] `http://192.168.10.20:8090/web/` shows no red alerts
- [ ] `~/homelab/backup/backup-homelab.sh` ends with `OK` and the set reaches the laptop
- [ ] Every app answers; Immich and Nextcloud counts match the backup's
- [ ] All four tailnet devices online; AdGuard and the fallback both answer DNS
