#! /bin/bash

# My own script to run while setting up a new system

clear
echo "Which flavour of linux is this system? \\1: Arch\\2: Fedora/Red Hat\\3: Ubuntu/Debian"
echo
read flavour
echo
echo "What kind of system is this? \\1: Personal System \\2: Barebones \\3: VM"
echo
read systype
echo
cd ~

if [ "$flavour" == 1 && "$systype" == 1]
	then
	sudo pacman -Syyu -y
	sudo pacman -S --needed base-devel vi vim nano git flatpak ttf-liberation-mono-nerd wezterm obsidian docker flameshot libreoffice-fresh docker-buildx python python-pynput python-pip python-virtualenv python-setuptools -y
	sudo flatpak install brave zed nomacs syncthingy vscodium heroicgameslauncher -y # nomacs - image viewer
	git clone https://aur.archlinux.org/yay.git
	cd yay
	makepkg -si -y
	yay -Sua
	yay -S docker-desktop
	
if [ "$flavour" == 1 && "$systype" == 2]
	then
	sudo pacman -Syyu -y
	sudo pacman -S --needed base-devel vi vim nano git flatpak ttf-liberation-mono-nerd wezterm obsidian docker flameshot libreoffice-fresh docker-buildx python python-pynput python-pip python-virtualenv python-setuptools -y
	sudo flatpak install brave zed nomacs syncthingy vscodium heroicgameslauncher -y

if [ "$systype" == 3 ]
	then
	sudo pacman -S open-vm-tools ttf-liberation-mono-nerd wezterm -y
	sudo systemctl status vmtoolsd.service
	for i in {5 4 3 2 1}
	do echo "$i . . "
	sleep 1
	done
	sudo systemctl enable vmtoolsd.service
	sudo systemctl start vmtoolsd.service
	sudo systemctl status vmtoolsd.service
	for i in {5 4 3 2 1}
	do echo "$i . . "
	sleep 1
	done
