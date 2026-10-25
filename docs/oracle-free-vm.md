# A free Oracle Cloud VM on your tailnet

Oracle's **Always Free** tier gives one ARM VM with up to **4 cores and 24 GB RAM**, 200 GB disk and
10 TB/month traffic, free for as long as the account is used. It's where clipping, OpenClaw, Forgejo and a
remote Claude Code run, so the laptop stays light.

Nothing here costs money **as long as you only pick shapes and sizes marked "Always Free"**. The card is
checked once (a small hold that is returned), and the account stays on the free tier unless you press
"Upgrade to Pay As You Go". Don't press it.

---

## 1. Make the account (10 minutes, on the laptop browser)

1. Open <https://signup.cloud.oracle.com>.
2. **Country:** India. Name and email: use a new email for the business (see the accounts plan), or yours.
3. **Home region:** pick **India South (Hyderabad)**. You can't change it later, and free ARM VMs are only
   made in the home region. (If Hyderabad says "out of capacity" later, the fix is retrying, not a new region.)
4. Verify the email, set a password (save it in Bitwarden), add the card. Wait for "Your account is ready"
   (can take up to 15 minutes; the email says when).

## 2. Make the network allow nothing but SSH (5 minutes)

New accounts get a default network with SSH (port 22) open to the internet. We keep it only until the VM
is on the tailnet, then close it in step 7.

Nothing to do here unless the wizard in step 3 asks: let it **create a new virtual cloud network** and a
**public subnet**, and tick **Assign a public IPv4 address**.

## 3. Create the VM (5 minutes)

1. Menu (☰) → **Compute → Instances → Create instance**.
2. **Name:** `oci-1`.
3. **Image and shape → Edit:**
   - Image: **Canonical Ubuntu 24.04** (not Minimal).
   - Shape: **Change shape → Ampere → VM.Standard.A1.Flex**. Set **OCPUs = 4**, **Memory = 24 GB**.
     The label must say **Always Free-eligible**.
4. **Networking:** the defaults from step 2 (new VCN, public subnet, public IPv4 = yes).
5. **Add SSH keys → Paste public keys.** On the laptop run this and paste what it prints:
   ```bash
   cat ~/.ssh/id_ed25519.pub
   ```
6. **Boot volume:** tick **Specify a custom boot volume size**, set **100 GB** (free up to 200 GB total).
7. **Create.** Wait until it says **Running**, then copy its **Public IP address**.

If it says **"Out of capacity for shape VM.Standard.A1.Flex"**: Hyderabad's free ARM pool is full at that
moment. Try again every hour, or try 2 OCPU / 12 GB first and resize later (Instance → Edit → Shape).

## 4. First login (from the laptop)

```bash
ssh -v ubuntu@<PUBLIC-IP>
```
`-v` prints each step; the last lines should end with `Authenticated to <ip>` and a `ubuntu@oci-1:~$` prompt.
Type `yes` when it asks about the fingerprint.

## 5. Make a one-time tailnet key (on the laptop)

Your tailnet runs on your own Headscale at `hs.meldev.duckdns.org`. This makes a key that works once,
for one hour:

```bash
ssh moosa@192.168.10.20 'docker exec headscale headscale preauthkeys create --user moosa --expiration 1h'
```
Copy the long key it prints. It is a password for joining your network: don't paste it anywhere else.

## 6. Set the VM up (one script, on the VM)

Still in the SSH session from step 4, paste this whole block. It prints every command it runs (`set -x`).

```bash
sudo bash -x <<'SETUP'
set -euo pipefail
# 1. updates and the basics
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y install unattended-upgrades fail2ban curl git htop ffmpeg python3-venv
dpkg-reconfigure -f noninteractive unattended-upgrades
# 2. Tailscale, joined to your Headscale
curl -fsSL https://tailscale.com/install.sh | sh
read -rp "Paste the tailnet key from step 5: " KEY
tailscale up --login-server https://hs.meldev.duckdns.org --authkey "$KEY" --hostname oci-1 --ssh
tailscale ip -4
# 3. Docker (for Forgejo and the clip workers)
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
# 4. 4 GB swap so a big render never kills anything
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo "DONE. Tailnet IP above. Log out and back in once for docker."
SETUP
```

The `tailscale ip -4` line prints the VM's tailnet address (`100.64.0.x`). Check from the laptop:
```bash
ping -c3 oci-1          # or the 100.64.0.x address
ssh -v ubuntu@oci-1     # now over the tailnet
```

## 7. Close the public door (Oracle console)

Once `ssh ubuntu@oci-1` works over the tailnet:

1. Instance page → **Primary VNIC → Subnet → Security Lists → Default Security List**.
2. Delete the **Ingress rule for port 22 from 0.0.0.0/0**.

Now nothing on the internet can reach the VM; you and your devices reach it through the tailnet only.
Test from the laptop that `ssh -v ubuntu@<PUBLIC-IP>` now **times out**, and `ssh ubuntu@oci-1` still works.

## 8. Keep it free and alive

- Oracle may reclaim an Always Free VM that sits **idle** for 7 days (CPU under 20%). The clip workers keep
  it busy; nothing to do.
- Billing → **Cost Analysis** should always say **₹0**. If it ever doesn't, tell Claude.

## Then tell Claude: "oci-1 is up"

Claude moves the clip pipeline, OpenClaw and a remote Claude Code there, and installs Forgejo.
