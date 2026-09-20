#! /bin/bash
# My own script to run while setting up a new system
# git clone https://www.github.com/cliffsandroses/my_linux_utils

set -e

# Check for script success at the end
check_success() {
    local exit_code=$?
    # If the script finished cleanly (exit 0) or was explicitly stopped,
    # and it was not a help request, log success.
    if [ "$exit_code" -eq 0 ] && [ "$EXIT_BY_HELP" = "false" ]; then
        log "SUCCESS: Setup completed successfully!"
    elif [ "$exit_code" -ne 0 ]; then
        log "FAILURE: Setup failed. Check log: $LOGFILE"
    fi
}
trap check_success EXIT

LOGFILE="setup_log.txt"
EXIT_BY_HELP="false"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# --- Visual Cleanup ---
# Function to print clear section headers
header() {
    echo -e "\n\033[1;34m>>> $1\033[0m"
    log "$1"
}

# Define run_cmd helper
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would have run: $@"
    else
        log "Running: $@"
        "$@"
    fi
}

safe_cd() {
    log "Changing directory to $1"
    cd "$1" || exit 1
}

show_help() {
    echo "Usage: ./Linux_SetupScript.sh [options]"
    echo "Options:"
    echo "  -d, --dry-run       Don't execute any commands, just log them"
    echo "  -s, --no-security   Skip security hardening"
    echo "  -l, --log-file FILE Log to the specified file"
    echo "  -h, --help          Show this help message"
    EXIT_BY_HELP="true"
    exit 0
}

# Argument Parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        --dry-run|-d) DRY_RUN=true ;;
        --no-security|-s) SKIP_SECURITY=true ;;
        --log-file|-l) LOGFILE="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# ... rest of your script ...
    install_essentials() {
    local pm=$1
    if [ "$pm" == "pacman" ]; then
        run_cmd sudo pacman -S --needed base-devel vim git htop nano fastfetch -y
    elif [ "$pm" == "dnf" ]; then
        run_cmd sudo dnf install -y vim git htop nano fastfetch
    elif [ "$pm" == "apt" ]; then
        run_cmd sudo apt install -y vim git htop nano fastfetch
    fi
}

install_dev_tools() {
    local pm=$1
    if [ "$pm" == "pacman" ]; then
        run_cmd sudo pacman -S --needed docker docker-buildx jdk-openjdk python python-pip -y
    elif [ "$pm" == "dnf" ]; then
        run_cmd sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin java-latest-openjdk python3 python3-pip
    elif [ "$pm" == "apt" ]; then
        run_cmd sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin openjdk-17-jdk python3 python3-pip
    fi
}

install_media_apps() {
    local pm=$1
    # Flatpak is the common denominator for your media apps
    run_cmd flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    run_cmd flatpak install -y flathub dev.zed.Zed org.nomacs.ImageLounge com.syncthing.Syncthing com.vscodium.codium org.heroicgameslauncher.hgl com.brave.Browser

    if [ "$pm" == "pacman" ]; then
        run_cmd sudo pacman -S --needed bluez blueman p7zip ttf-liberation-mono-nerd wezterm obsidian flameshot libreoffice-fresh -y
    elif [ "$pm" == "dnf" ]; then
        run_cmd sudo dnf install -y bluez blueman p7zip tar liberation-mono-fonts wezterm obsidian flameshot libreoffice-fresh
    elif [ "$pm" == "apt" ]; then
        run_cmd sudo apt install -y bluez blueman p7zip-full tar fonts-liberation2 obsidian flameshot libreoffice-fresh
    fi
}

install_hardware_drivers() {
    local pm=$1
    log "Detecting graphics hardware..."

    # Simple GPU detection using lspci
    if lspci | grep -i nvidia &> /dev/null; then
        log "NVIDIA GPU detected. Installing drivers..."
        if [ "$pm" == "pacman" ]; then
            run_cmd sudo pacman -S --needed nvidia nvidia-utils nvidia-settings -y
        elif [ "$pm" == "dnf" ]; then
            run_cmd sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
        elif [ "$pm" == "apt" ]; then
            run_cmd sudo apt install -y nvidia-driver-535
        fi
    elif lspci | grep -iE "amdgpu|radeon" &> /dev/null; then
        log "AMD GPU detected. Ensuring open source driver support..."
        if [ "$pm" == "pacman" ]; then
            run_cmd sudo pacman -S --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon -y
        elif [ "$pm" == "dnf" ]; then
            run_cmd sudo dnf install -y mesa-dri-drivers mesa-vulkan-drivers
        elif [ "$pm" == "apt" ]; then
            run_cmd sudo apt install -y mesa-vulkan-drivers libgl1-mesa-dri
        fi
    else
        log "No dedicated GPU detected or using standard drivers."
    fi
}

apply_security_hardening() {
    if [ "$SKIP_SECURITY" == "true" ]; then
        log "Security hardening skipped by user."
        return
    fi
    local pm=$1
    log "Applying system security hardening..."

    # Configure firewall
    if [ "$pm" == "pacman" ] || [ "$pm" == "apt" ]; then
        if command -v ufw &> /dev/null; then
            run_cmd sudo ufw default deny incoming
            run_cmd sudo ufw default allow outgoing
            run_cmd sudo ufw allow ssh
            run_cmd sudo ufw --force enable
            log "UFW firewall enabled and configured."
        fi
    elif [ "$pm" == "dnf" ]; then
        if command -v firewalld &> /dev/null; then
            run_cmd sudo systemctl enable --now firewalld
            run_cmd sudo firewall-cmd --set-default-zone=drop
            run_cmd sudo firewall-cmd --permanent --add-service=ssh
            run_cmd sudo firewall-cmd --reload
            log "Firewalld configured and set to drop."
        fi
    fi

    # Install/Enable fail2ban
    if command -v fail2ban-server &> /dev/null; then
        run_cmd sudo systemctl enable --now fail2ban
        log "Fail2ban enabled."
    fi

    log "Security hardening complete."
}

countdown() {
    for i in $(seq $1 -1 1); do
        echo -n "$i . . "
        sleep 1
    done
    echo "Now"
}

clear
echo "Which flavour of linux is this system?"
echo "1: Arch"
echo "2: Fedora/Red Hat"
echo "3: Ubuntu/Debian"
echo "4: Home server"
echo
read flavour
log "Flavour selected: $flavour"
echo
echo "What kind of system is this?"
echo "1: Personal System"
echo "2: Barebones"
echo "3: VM"
echo
read systype
log "System type selected: $systype"
echo
cd ~
log "Detecting CPU architecture..."
if lscpu | grep -i "Intel" &> /dev/null; then
    arch=1
    log "Detected Intel CPU"
elif lscpu | grep -i "AMD" &> /dev/null; then
    arch=2
    log "Detected AMD CPU"
else
    echo "Could not auto-detect CPU. Choose: 1: Intel, 2: AMD"
    read arch
    log "Architecture selected: $arch"
fi
echo
# Use header for sections
header "Starting system setup"
countdown 3
header "Running pre-flight checks..."

# 1. Root/Sudo Check
if [ "$EUID" -eq 0 ]; then
    # Must use echo directly here because log() might not be fully ready
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Error: Please do not run this script as root." | tee -a "$LOGFILE"
    exit 1
fi

# 2. Network Check
if ! ping -c 1 8.8.8.8 &> /dev/null; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Error: No internet connection detected." | tee -a "$LOGFILE"
    exit 1
fi

# 3. Dependency Check
REQUIRED_CMDS=("git" "curl" "sed" "lscpu" "flatpak" "tee" "grep")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Error: Required dependency '$cmd' is not installed." | tee -a "$LOGFILE"
        exit 1
    fi
done

# 4. Disk Space Check
FREE_SPACE=$(df -m ~ | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE" -lt 2048 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Error: Less than 2GB free space in home directory." | tee -a "$LOGFILE"
    exit 1
fi

header "Pre-flight checks passed."

case $flavour in

	    1)
	        if [ "$systype" -eq 1 ]; then
	            header "Arch Linux Personal Setup"
	            # Force full database refresh and system update
	            run_cmd sudo pacman -Syyu --noconfirm
	            
	            run_cmd sudo mkdir -p /etc/pacman.d
	            run_cmd sudo sed -i -e "s/#Color/Color/g" -e "s/#ParalledDownloads/ParallelDownloads/g" /etc/pacman.conf
	            run_cmd sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.original
	            
	            # Reflector updates mirrors, then sync again
	            run_cmd sudo reflector --verbose --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
	            run_cmd sudo pacman -Syy --noconfirm
				install_essentials "pacman"
				install_dev_tools "pacman"
				install_media_apps "pacman"
				install_hardware_drivers "pacman"
				apply_security_hardening "pacman"
				run_cmd sudo pacman -Syu --noconfirm
				log "Package Installation complete"
				run_cmd sudo modprobe btusb
				run_cmd sudo systemctl status bluetooth
				countdown 5
				run_cmd sudo systemctl enable --now bluetooth
				log "Installing AUR helpers and extras"
				if [ "$DRY_RUN" == "false" ]; then
					if [ ! -d "yay" ]; then
						run_cmd git clone https://aur.archlinux.org/yay.git
					fi
				fi
				safe_cd yay
				run_cmd makepkg -si --noconfirm
				run_cmd yay -Sua --noconfirm
				run_cmd yay -S docker-desktop preload --noconfirm
				run_cmd sudo groupadd docker 2>/dev/null || true
				run_cmd sudo usermod -aG docker $USER
				run_cmd sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
				run_cmd sudo chmod g+rwx "$HOME/.docker" -R
				if [ $arch -eq 1 ]; then
					ucode=Intel
				elif [ $arch -eq 2 ]; then
					ucode=AMD
				fi
				log "Beginning $ucode specific setup"
				countdown 3
				if [ $arch -eq 1 ]; then
					run_cmd sudo pacman -S intel-ucode --noconfirm
					run_cmd sudo grub-mkconfig -o /boot/grub/grub.cfg
				elif [ $arch -eq 2 ]; then
					run_cmd sudo pacman -S amd-ucode --noconfirm
					run_cmd sudo grub-mkconfig -o /boot/grub/grub.cfg
				fi

			elif [ "$systype" -eq 2 ]; then
				log "Updating and installing barebones applications"
				sudo pacman -Syyu -y
				install_essentials "pacman"
				install_dev_tools "pacman"
				sudo flatpak install flathub com.brave.Browser dev.zed.Zed org.nomacs.ImageLounge com.syncthing.Syncthing com.vscodium.codium org.heroicgameslauncher.hgl -y

			elif [ "$systype" -eq 3 ]; then
				log "Installing VM tools"
				sudo pacman -S open-vm-tools ttf-liberation-mono-nerd wezterm -y
				sudo systemctl enable --now vmtoolsd.service
				countdown 5
				log "VM tools installed"
			fi ;;

	2)
		if [ "$systype" -eq 1 ]; then
			sudo dnf update -y
			install_essentials "dnf"
			install_dev_tools "dnf"
			install_media_apps "dnf"
			install_hardware_drivers "dnf"
			apply_security_hardening "dnf"
			log "Fedora setup complete!"
		elif [ "$systype" -eq 2 ]; then
			sudo dnf update -y
			install_essentials "dnf"
			install_dev_tools "dnf"
		elif [ "$systype" -eq 3 ]; then
			sudo dnf install -y open-vm-tools
			sudo systemctl enable --now vmtoolsd
		fi ;;

	3)
	if [ "$systype" -eq 1 ]; then
		sudo apt update && sudo apt upgrade -y
		install_essentials "apt"
		install_dev_tools "apt"
		install_media_apps "apt"
		install_hardware_drivers "apt"
		apply_security_hardening "apt"
		log "Ubuntu/Debian setup complete!"
	elif [ "$systype" -eq 2 ]; then
		sudo apt update && sudo apt upgrade -y
		install_essentials "apt"
		install_dev_tools "apt"
	elif [ "$systype" -eq 3 ]; then
		sudo apt install -y open-vm-tools
		sudo systemctl enable --now open-vm-tools
	fi ;;

	4)
	log "Setting up as Home Server..."
	log "Updating system..."
	if command -v apt &> /dev/null; then
		run_cmd sudo apt update && run_cmd sudo apt upgrade -y
		run_cmd sudo apt install -y vim git htop curl wget ufw fail2ban openssh-server docker.io
	elif command -v dnf &> /dev/null; then
		run_cmd sudo dnf update -y
		run_cmd sudo dnf install -y vim git htop curl wget firewalld fail2ban openssh-server docker-ce
		run_cmd sudo systemctl enable --now firewalld
	elif command -v pacman &> /dev/null; then
		run_cmd sudo pacman -Syu --noconfirm
		run_cmd sudo pacman -S --noconfirm vim git htop curl wget ufw fail2ban openssh docker
		run_cmd sudo systemctl enable --now ufw
	fi

	log "Enabling SSH..."
	run_cmd sudo systemctl enable --now ssh

	log "Enabling Firewall..."
	if command -v ufw &> /dev/null; then
		run_cmd sudo ufw allow ssh
		run_cmd sudo ufw --force enable
	fi

	log "Home Server setup complete! Please ensure you have set up SSH keys." ;;

	esac

	echo "Would you like to install dotfiles from the 'config/' directory to your home folder? (y/n)"
	read setup_dots
	if [ "$setup_dots" == "y" ]; then
	    echo "Installing dotfiles..."
	    for file in config/*; do
	        ln -sf "$(pwd)/$file" "$HOME/.$(basename "$file")"
	        echo "Linked $(basename "$file")"
	    done
	    echo "Dotfiles installed."
	fi
