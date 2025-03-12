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
  		echo "Syncing Pacman in"
		for i in 3 2 1
   			do echo "$i . . "
			sleep 1
		done
  		echo "Now"
  		sudo pacman -Syy -y
    		echo
    		echo "Installing applications."
		echo
  		sudo pacman -S --needed base-devel vim nano git flatpak ttf-liberation-mono-nerd wezterm obsidian docker flameshot libreoffice-fresh docker-buildx python python-pynput python-pip python-virtualenv python-setuptools -y
    		echo
      		echo "Package Installation from pacman is done!"
		echo
  		echo "Installing packages from Flatpak in"
		for i in 3 2 1
   			do echo "$i . . "
			sleep 1
		done
  		echo "Now"
		sudo flatpak install brave zed nomacs syncthingy vscodium heroicgameslauncher -y # nomacs - image viewer
		git clone https://aur.archlinux.org/yay.git # installing yay
		cd yay
		makepkg -si -y
		yay -Sua
		yay -S docker-desktopx
  		sudo groupadd docker # adding docker to group
    		sudo usermod -aG docker $USER
      		newgrp docker
		sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
		sudo chmod g+rwx "$HOME/.docker" -R
	
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
			do echo "$i . . "
			sleep 1
		done
  		echo "Done!"
		sudo systemctl enable vmtoolsd.service
		sudo systemctl start vmtoolsd.service
		sudo systemctl status vmtoolsd.service
		for i in 5 4 3 2 1
			do echo "$i . . "
			sleep 1
		done
  		echo "Done!"
  	fi
   ;;

   2)
