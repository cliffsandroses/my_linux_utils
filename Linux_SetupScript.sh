#! /bin/bash

# My own script to run while setting up a new system

clear
echo "Which flavour of linux is this system?"
echo "1: Arch"
echo "2: Fedora/Red Hat"
echo "3: Ubuntu/Debian"
echo
read flavour
echo
echo "What kind of system is this?"
echo "1: Personal System"
echo "2: Barebones"
echo "3: VM"
echo
read systype
echo
cd ~

choice $flavour in

1(
	if [ "$systype" == 1]
		then
  		echo "Do you have an Intel or AMD cpu?"
    		echo "If you do not know exit this script and run 'lscpu | grep Model\ name'"
    		echo
      		echo "1: Intel"
		echo "2: AMD"
  		echo
    		read arch
      		echo
  		echo "Starting script"
		for i in 3 2 1
   			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
  		echo
    		echo "Making changes to pacman"
		echo
  		sudo cd /etc
  		sudo sed -i -e "s/#Color/Color/g" -e "s/#ParalledDownloads/ParallelDownloads/g" pacman.conf -y
    		sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.original -y
      		sudo pacman -Syv -y
      		sudo reflector --verbose --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist -y
  		echo "Syncing Pacman in"
		for i in 3 2 1
   			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
  		echo "Now"
  		sudo pacman -Syyv -y
    		echo
    		echo "Installing applications."
		echo
  		sudo pacman -S --needed base-devel linux-headers linux-lts linux-lts-headers bluez blueman p7zip tar jdk-openjdk bluez-utils fastfetch htop vim nano git flatpak ttf-liberation-mono-nerd wezterm obsidian docker flameshot libreoffice-fresh docker-buildx python python-pynput python-pip python-virtualenv python-setuptools -y
		sudo pacman -Syu -y
      		echo
      		echo "Package Installation from pacman is done!"
		echo
  		sudo modprobe btusb
    		sudo systemctl status bluetooth
		for i in 5 4 3 2 1
			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
		sudo systemctl enable bluetooth
		sudo systemctl start bluetooth
		sudo systemctl status bluetooth
  		echo "Installing packages from Flatpak in"
		for i in 3 2 1
   			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
  		echo "Now"
		sudo flatpak install brave zed nomacs syncthingy vscodium heroicgameslauncher -y # nomacs - image viewer
		git clone https://aur.archlinux.org/yay.git # installing yay
		cd yay
		makepkg -si -y
		yay -Sua
		yay -S docker-desktop preload -y
  		sudo groupadd docker # adding docker to group
    		sudo usermod -aG docker $USER
      		newgrp docker
		sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
		sudo chmod g+rwx "$HOME/.docker" -R
  		echo
    		if [ $arch -eq 1 ]
      			then ucode=Intel
	 	elif [ $arch -eq 2 ]
   			then ucode=AMD	
      		fi
    		echo "Beginning $ucode specific setup"
      		for i in 3 2 1
   			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
  		echo "Now"
		echo 
  		if [ $arch -eq 1 ]
    			then 
       			sudo pacman -S intel-ucode
	  		sudo grub-mkconfig -o /boot/grub/grub.cfg
     		elif [ $arch -eq 2 ] # Incomplete, add option to setup a cli only machine
       			then
	elif [ "$systype" == 2]
		then
		sudo pacman -Syyu -y
		sudo pacman -S --needed base-devel vim git flatpak ttf-liberation-mono-nerd wezterm obsidian docker flameshot libreoffice-fresh docker-buildx python python-pynput python-pip python-virtualenv python-setuptools -y
		sudo flatpak install brave zed nomacs syncthingy vscodium heroicgameslauncher -y

	elif [ "$systype" == 3 ]
		then
		sudo pacman -S open-vm-tools ttf-liberation-mono-nerd wezterm -y
		sudo systemctl status vmtoolsd.service
		for i in 5 4 3 2 1
			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
  		echo "Done!"
		sudo systemctl enable vmtoolsd.service
		sudo systemctl start vmtoolsd.service
		sudo systemctl status vmtoolsd.service
		for i in 5 4 3 2 1
			do echo "$i . . " |  tr -d '\n'
			sleep 1
		done
  		echo "Done!"
  	fi
   ;;

   2)
