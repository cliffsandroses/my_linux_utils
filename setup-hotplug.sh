#!/bin/bash
# Generic hotplug setup script for CasaOS storage

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Ensure root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[✖] Error: Please run this script with sudo.${NC}"
  exit 1
fi

# Load config if it exists
if [ -f "./config" ]; then
    source ./config
else
    echo -e "${RED}[✖] Error: 'config' file not found. Please create it first.${NC}"
    exit 1
fi

# Validate variables
if [[ -z "$USER_NAME" || -z "$DRIVE_UUID" || -z "$MOUNT_BASE" ]]; then
    echo -e "${RED}[✖] Error: 'config' file is missing required variables (USER_NAME, DRIVE_UUID, MOUNT_BASE).${NC}"
    exit 1
fi

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}      Generic CasaOS Hotplug Storage Setup       ${NC}"
echo -e "${BLUE}=================================================${NC}\n"

# Create the internal fallback directory
echo -e "${BLUE}[*] Step 1: Creating internal fallback directory (/DATA/)...${NC}"
mkdir -p /DATA/
chown -R "$USER_NAME":"$(id -gn "$USER_NAME")" /DATA/
echo -e "${GREEN}  [✔] Permissions set for user '$USER_NAME'.${NC}\n"

# Write the background switcher script
echo -e "${BLUE}[*] Step 2: Writing background switcher script...${NC}"
cat << 'EOF' > /usr/local/bin/casaos-storage-switch.sh
#!/bin/bash

# Configuration: Use UUID to find the mount point dynamically
DRIVE_UUID="96c969af-bd2a-4efa-8d7b-9b45b04a77f8"
SPECIFIC_FOLDER="DATA"
FALLBACK_DIR="/DATA/"
ACTIVE_LINK="/home/moosa/casaos_active"
LOG_FILE="/var/log/casaos-hotplug.log"
MAX_LINES=1500

log_action() {
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] - $1" >> "$LOG_FILE"
}

# Dynamically find the mount point by UUID
MOUNT_POINT=$(lsblk -no MOUNTPOINT,UUID | grep "$DRIVE_UUID" | awk "{print \$1}")

if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT/$SPECIFIC_FOLDER" ]; then
    TARGET_PATH="$MOUNT_POINT/$SPECIFIC_FOLDER"
    log_action "External drive active at $MOUNT_POINT: Routing link to $TARGET_PATH"
    ln -sfn "$TARGET_PATH" "$ACTIVE_LINK"
    systemctl restart docker
    log_action "Docker restarted."
else
    log_action "External drive detached: Routing link to $FALLBACK_DIR"
    ln -sfn "$FALLBACK_DIR" "$ACTIVE_LINK"
    systemctl restart docker
    log_action "Docker restarted."
fi
EOF

chmod +x /usr/local/bin/casaos-storage-switch.sh
echo -e "${GREEN}  [✔] Switcher script saved to /usr/local/bin/.${NC}\n"

# Create systemd service
echo -e "${BLUE}[*] Step 3: Configuring systemd background service...${NC}"
cat << EOF > /etc/systemd/system/casaos-storage-switch.service
[Unit]
Description=Hotplug Toggle CasaOS Storage Paths

[Service]
Type=oneshot
ExecStart=/usr/local/bin/casaos-storage-switch.sh
EOF

systemctl daemon-reload

# Create udev rule
echo -e "${BLUE}[*] Step 4: Writing udev hardware rules...${NC}"
cat << EOF > /etc/udev/rules.d/99-casaos-storage.rules
SUBSYSTEM=="block", ENV{ID_FS_UUID}=="$DRIVE_UUID", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}+="casaos-storage-switch.service"
SUBSYSTEM=="block", ENV{ID_FS_UUID}=="$DRIVE_UUID", ACTION=="remove", TAG+="systemd", ENV{SYSTEMD_WANTS}+="casaos-storage-switch.service"
EOF

udevadm control --reload-rules
echo -e "${GREEN}  [✔] Hardware rules applied.${NC}\n"

echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}[✔] Setup Complete!${NC}"
echo -e "${GREEN}=================================================${NC}\n"
