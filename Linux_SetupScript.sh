#!/usr/bin/env bash
# ==========================================
# Linux Automated Setup Script
# Interactive system type + optional features
# Professional visual output
# ==========================================

set -euo pipefail
IFS=$'\n\t'
LOGFILE="$HOME/setup.log"

# ---------- Logging ----------
info()  { echo -e "\e[32m✔ [INFO]\e[0m $*" | tee -a "$LOGFILE"; }
warn()  { echo -e "\e[33m⚠ [WARN]\e[0m $*" | tee -a "$LOGFILE"; }
error() { echo -e "\e[31m✖ [ERROR]\e[0m $*" | tee -a "$LOGFILE"; }
step()  { echo -e "\e[36m→ $*\e[0m" | tee -a "$LOGFILE"; }

# ---------- Section Heading ----------
section() {
    echo -e "\n\e[34m==========================================\e[0m"
    echo -e "\e[34m  $1\e[0m"
    echo -e "\e[34m==========================================\e[0m\n"
}

# ---------- Countdown ----------
countdown() {
    echo
    for i in 3 2 1; do
        echo -ne "\rStarting in $i ..."
        sleep 1
    done
    echo -e "\rStarting now!   "
}

# ---------- Spinner ----------
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    echo "    "
}

# ---------- Flatpak Apps ----------
FLATPAK_APPS=(
  "com.brave.Browser"
  "dev.zed.Zed"
  "org.nomacs.ImageLounge"
  "com.github.zocker_160.SyncThingy"
  "com.vscodium.codium"
  "com.heroicgameslauncher.hgl"
)

# ---------- Dev Tools ----------
DEV_TOOLS=(
    "python python-pynput python-pip python-virtualenv python-setuptools"
    "jdk-openjdk"
)

# ---------- Optional Games Placeholder ----------
GAMES=(
    # Add gaming packages later
)

# ---------- Detect Distro ----------
detect_distro() {
    section "Detecting Linux Distro"
    if [[ -f /etc/arch-release ]]; then
        DISTRO="arch"
    elif [[ -f /etc/fedora-release ]]; then
        DISTRO="fedora"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
    else
        error "Unsupported distribution."
        exit 1
    fi
    info "Detected distro: $DISTRO"
}

# ---------- Detect CPU ----------
detect_cpu() {
    section "Detecting CPU"
    if lscpu | grep -qi intel; then
        CPU="intel"
    elif lscpu | grep -qi amd; then
        CPU="amd"
    else
        CPU="unknown"
    fi
    info "CPU detected: $CPU"
}

# ---------- Detect VM ----------
detect_vm() {
    section "Detecting Virtual Machine"
    if systemd-detect-virt | grep -qi vmware; then
        IS_VM="true"
        warn "VMware VM detected."
        read -rp "Proceed as VM system? [y/N]: " vm_confirm
        if [[ ! "$vm_confirm" =~ ^[Yy]$ ]]; then
            info "Proceeding as physical machine."
            IS_VM="false"
        fi
    else
        IS_VM="false"
    fi
    info "VM status: $IS_VM"
}

# ---------- Select System Type ----------
select_system_type() {
    section "Select System Type"
    echo "1) Personal System"
    echo "2) Barebones"
    echo "3) VM"
    read -rp "Enter choice [1-3]: " SYSTEM_TYPE

    case "$SYSTEM_TYPE" in
        1) SYSTEM_TYPE_NAME="personal" ;;
        2) SYSTEM_TYPE_NAME="barebones" ;;
        3) SYSTEM_TYPE_NAME="vm" ;;
        *) error "Invalid choice"; exit 1 ;;
    esac
    info "System type selected: $SYSTEM_TYPE_NAME"
}

# ---------- Optional Features ----------
select_optional_features() {
    section "Select Optional Features"
    echo "1) Minimal (core only)"
    echo "2) Full (GUI + dev tools + optional apps)"
    echo "3) Dev Tools only"
    echo "4) Games only"
    read -rp "Enter choice [1-4, blank=default]: " FEATURE_CHOICE

    case "$FEATURE_CHOICE" in
        1) FEATURE="minimal" ;;
        2) FEATURE="full" ;;
        3) FEATURE="dev" ;;
        4) FEATURE="games" ;;
        "") 
            if [[ "$SYSTEM_TYPE_NAME" == "personal" ]]; then
                FEATURE="full"
            else
                FEATURE="minimal"
            fi
            ;;
        *) error "Invalid feature choice"; exit 1 ;;
    esac
    info "Optional feature selected: $FEATURE"
}

# ---------- Core Packages ----------
install_core_packages() {
    section "Installing Core Packages"
    step "Packages: git, curl, wget, vim, nano, htop"
    case "$DISTRO" in
        arch)
            sudo pacman -Syu --noconfirm &
            spinner $!
            sudo pacman -S --needed --noconfirm base-devel git curl wget htop vim nano &
            spinner $!
            ;;
        fedora)
            sudo dnf upgrade -y &
            spinner $!
            sudo dnf install -y git curl wget htop vim nano &
            spinner $!
            ;;
        debian)
            sudo apt update && sudo apt upgrade -y &
            spinner $!
            sudo apt install -y git curl wget htop vim nano &
            spinner $!
            ;;
    esac
    info "Core packages installed"
}

# ---------- GUI / Flatpak ----------
install_gui_apps() {
    section "Installing GUI Apps (Flatpak)"
    if ! flatpak remotes | grep -q flathub; then
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    for app in "${FLATPAK_APPS[@]}"; do
        step "Installing $app"
        flatpak install -y flathub "$app" &
        spinner $!
    done
    info "GUI apps installed"
}

# ---------- Dev Tools ----------
install_dev_tools() {
    section "Installing Development Tools"
    step "Packages: ${DEV_TOOLS[*]}"
    case "$DISTRO" in
        arch) sudo pacman -S --needed --noconfirm "${DEV_TOOLS[@]}" &
             spinner $! ;;
        fedora) sudo dnf install -y "${DEV_TOOLS[@]}" &
             spinner $! ;;
        debian) sudo apt install -y "${DEV_TOOLS[@]}" &
             spinner $! ;;
    esac
    info "Development tools installed"
}

# ---------- Docker ----------
install_docker() {
    if [[ "$SYSTEM_TYPE_NAME" != "personal" ]]; then
        info "Skipping Docker (Personal systems only)"
        return
    fi
    section "Installing Docker"
    case "$DISTRO" in
        arch) sudo pacman -S --needed --noconfirm docker docker-buildx &
             spinner $! ;;
        fedora) sudo dnf install -y docker docker-compose &
             spinner $! ;;
        debian) sudo apt install -y docker.io docker-compose &
             spinner $! ;;
    esac
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker "$USER"
    info "Docker installed and configured"
}

# ---------- Bluetooth ----------
setup_bluetooth() {
    if [[ "$SYSTEM_TYPE_NAME" != "personal" ]]; then
        info "Skipping Bluetooth (Personal systems only)"
        return
    fi
    section "Setting Up Bluetooth"
    sudo modprobe btusb || true
    sudo systemctl enable bluetooth
    sudo systemctl start bluetooth
    info "Bluetooth configured"
}

# ---------- CPU Microcode ----------
install_microcode() {
    section "Installing CPU Microcode"
    case "$DISTRO" in
        arch)
            if [[ "$CPU" == "intel" ]]; then
                sudo pacman -S --noconfirm intel-ucode &
                spinner $!
            elif [[ "$CPU" == "amd" ]]; then
                sudo pacman -S --noconfirm amd-ucode &
                spinner $!
            fi
            sudo grub-mkconfig -o /boot/grub/grub.cfg || true
            ;;
    esac
    info "CPU microcode installed"
}

# ---------- VM Tools ----------
install_vm_tools() {
    if [[ "$IS_VM" == "true" ]]; then
        section "Installing VM Tools"
        case "$DISTRO" in
            arch) sudo pacman -S --noconfirm open-vm-tools &
                 spinner $! ;;
        esac
        sudo systemctl enable vmtoolsd.service
        sudo systemctl start vmtoolsd.service
        info "VM tools installed"
    fi
}

# ---------- ASCII Header ----------
print_header() {
    echo -e "\e[36m
  _     _      _            _     
 | |   (_) ___| | ___   ___| | __ 
 | |   | |/ _ \ |/ _ \ / __| |/ / 
 | |___| |  __/ | (_) | (__|   <  
 |_____|_|\___|_|\___/ \___|_|\_\
\e[0m"
}

# ---------- MAIN ----------
print_header
countdown
detect_distro
detect_cpu
detect_vm
select_system_type
select_optional_features

install_core_packages
install_docker
setup_bluetooth
install_microcode
install_vm_tools

# Conditional optional features
case "$FEATURE" in
    full)
        install_gui_apps
        install_dev_tools
        ;;
    dev)
        install_dev_tools
        ;;
    games)
        # Placeholder for future games
        ;;
    minimal)
        info "Minimal install selected; skipping optional features"
        ;;
esac

# Summary
section "Setup Complete!"
echo -e "System Type: $SYSTEM_TYPE_NAME"
echo -e "Distro: $DISTRO"
echo -e "CPU: $CPU"
echo -e "VM: $IS_VM"
echo -e "Features Installed: $FEATURE"
echo -e "Log file: $LOGFILE"
echo -e "Reboot recommended."