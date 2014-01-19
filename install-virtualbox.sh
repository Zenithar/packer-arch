#!/usr/bin/env bash

DISK='/dev/sda'
FQDN='vagrant-arch.vagrantup.com'
KEYMAP='us'
LANGUAGE='en_US.UTF-8'
PASSWORD=$(/usr/bin/openssl passwd -crypt 'vagrant')
TIMEZONE='UTC'

CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'
BOOT_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"
TARGET_DIR='/mnt'

echo "==> clearing partition table on ${DISK}"
/usr/bin/sgdisk --zap ${DISK}

echo "==> destroying magic strings and signatures on ${DISK}"
/usr/bin/dd if=/dev/zero of=${DISK} bs=512 count=2048
/usr/bin/wipefs --all ${DISK}

echo "==> creating partitions on ${DISK}"
/usr/bin/sgdisk --new=1:0:+100M ${DISK}
/usr/bin/sgdisk --new=2:0:0 ${DISK}

echo "==> setting ${DISK} bootable"
/usr/bin/sgdisk ${DISK} --attributes=1:set:2

echo '==> creating /boot filesystem (ext4)'
/usr/bin/mkfs.ext4 -F -m 0 -q -L boot ${BOOT_PARTITION}

echo '==> creating /root filesystem (btrfs)'
/usr/bin/mkfs.btrfs -f -L root ${ROOT_PARTITION}

echo "==> mounting ${ROOT_PARTITION} to ${TARGET_DIR}"
/usr/bin/mount ${ROOT_PARTITION} ${TARGET_DIR}

echo '==> creating BTRFS subvolumes'
cd ${TARGET_DIR}
/usr/bin/btrfs subvolume snapshot . __active
/usr/bin/mkdir __snapshot
cd ${TARGET_DIR}/__active
/usr/bin/btrfs subvolume create home
/usr/bin/btrfs subvolume create var
/usr/bin/btrfs subvolume create usr
/usr/bin/btrfs subvolume create data
/usr/bin/chmod 755 ../\__active var usr home data
cd
/usr/bin/umount ${ROOT_PARTITION}

echo "==> remounting ${ROOT_PARTITION} to ${TARGET_DIR} on volume '__active'"
/usr/bin/mount -o rw,relatime,compress=lzo,ssd,discard,space_cache,autodefrag,inode_cache,subvol=__active ${ROOT_PARTITION} ${TARGET_DIR}

echo "==> mounting ${BOOT_PARTITION} to ${TARGET_DIR}/boot"
mkdir ${TARGET_DIR}/boot
/usr/bin/mount -o noatime,errors=remount-ro ${BOOT_PARTITION} ${TARGET_DIR}/boot

echo '==> selecting mirrors'
/usr/bin/pacman -Sy --noconfirm reflector git
/usr/bin/reflector -l 50 -p http --sort rate --save /etc/pacman.d/mirrorlist

echo '==> bootstrapping the base installation'
/usr/bin/pacstrap ${TARGET_DIR} base base-devel
/usr/bin/arch-chroot ${TARGET_DIR} pacman -S --noconfirm gptfdisk btrfs-progs openssh syslinux
cd ${TARGET_DIR}/root
/usr/bin/git clone https://github.com/xtfxme/mkinitcpio-btrfs
cd 
/usr/bin/arch-chroot ${TARGET_DIR} syslinux-install_update -i -a -m
/usr/bin/sed -i 's/sda3/sda2/' "${TARGET_DIR}/boot/syslinux/syslinux.cfg"
/usr/bin/sed -i 's/TIMEOUT 50/TIMEOUT 10/' "${TARGET_DIR}/boot/syslinux/syslinux.cfg"

echo '==> generating the filesystem table'
/usr/bin/genfstab -U -p ${TARGET_DIR} >> "${TARGET_DIR}/etc/fstab"

echo '==> generating the system configuration script'
/usr/bin/install --mode=0755 /dev/null "${TARGET_DIR}${CONFIG_SCRIPT}"

cat <<-EOF > "${TARGET_DIR}${CONFIG_SCRIPT}"
	echo '${FQDN}' > /etc/hostname
	/usr/bin/ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
	/usr/bin/hwclock --systohc --utc
	echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf
	/usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
	/usr/bin/locale-gen
	/usr/bin/usermod --password ${PASSWORD} root
	# https://wiki.archlinux.org/index.php/Network_Configuration#Device_names
	/usr/bin/ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules
	/usr/bin/ln -s '/usr/lib/systemd/system/dhcpcd@.service' '/etc/systemd/system/multi-user.target.wants/dhcpcd@eth0.service'
	/usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
	/usr/bin/systemctl enable sshd.service
	
	# btrfs
	mkdir -p /var/lib/btrfs
	echo '/dev/sda2		/var/lib/btrfs rw,relatime,space_cache,subvolid=0    0 0' >> /etc/fstab
	cd /root/mkinitcpio-btrfs
	makepkg -si --asroot --noconfirm
	/usr/bin/sed -i 's/fsck/btrfs_advanced/' /etc/mkinitcpio.conf
	/usr/bin/mkinitcpio -p linux
	/usr/bin/syslinux-install_update -i -a -m

    # Install yaourt
    curl -O https://aur.archlinux.org/packages/pa/package-query/package-query.tar.gz
    tar xvf package-query.tar.gz
    cd package-query
    makepkg -si --asroot --noconfirm
    cd ..
    curl -O https://aur.archlinux.org/packages/ya/yaourt/yaourt.tar.gz
    tar xvf yaourt.tar.gz
    cd yaourt
    makepkg -si --asroot --noconfirm
    cd ..
    rm -rf yaourt* package-query*

	# VirtualBox Guest Additions
	/usr/bin/pacman -S --noconfirm linux-headers virtualbox-guest-utils virtualbox-guest-dkms
	echo -e 'vboxguest\nvboxsf\nvboxvideo' > /etc/modules-load.d/virtualbox.conf
	guest_version=\$(/usr/bin/pacman -Q virtualbox-guest-dkms | awk '{ print \$2 }' | cut -d'-' -f1)
	kernel_version="\$(/usr/bin/pacman -Q linux | awk '{ print \$2 }')-ARCH"
	/usr/bin/dkms install "vboxguest/\${guest_version}" -k "\${kernel_version}/x86_64"
	/usr/bin/systemctl enable dkms.service
	/usr/bin/systemctl enable vboxservice.service

	# Vagrant-specific configuration
	/usr/bin/groupadd vagrant
	/usr/bin/useradd --password ${PASSWORD} --comment 'Vagrant User' --create-home --gid users --groups vagrant,vboxsf vagrant
	echo 'Defaults env_keep += "SSH_AUTH_SOCK"' > /etc/sudoers.d/10_vagrant
	echo 'vagrant ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/10_vagrant
	/usr/bin/chmod 0440 /etc/sudoers.d/10_vagrant
	/usr/bin/install --directory --owner=vagrant --group=users --mode=0700 /home/vagrant/.ssh
	/usr/bin/curl --output /home/vagrant/.ssh/authorized_keys https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub
	/usr/bin/chown vagrant:users /home/vagrant/.ssh/authorized_keys
	/usr/bin/chmod 0600 /home/vagrant/.ssh/authorized_keys

	# Docker
	/usr/bin/pacman -S --noconfirm docker
	/usr/bin/systemctl enable docker.service
	echo -e 'net.ipv4.ip_forward=1' > /etc/sysctl.d/docker.conf

	# clean up
	/usr/bin/pacman -Rcns --noconfirm gptfdisk
	/usr/bin/pacman -Scc --noconfirm
EOF

echo '==> entering chroot and configuring system'
/usr/bin/arch-chroot ${TARGET_DIR} ${CONFIG_SCRIPT}
rm "${TARGET_DIR}${CONFIG_SCRIPT}"

# http://comments.gmane.org/gmane.linux.arch.general/48739
echo '==> adding workaround for shutdown race condition'
/usr/bin/install --mode=0644 poweroff.timer "${TARGET_DIR}/etc/systemd/system/poweroff.timer"

echo '==> installation complete!'
/usr/bin/sleep 3
/usr/bin/umount ${TARGET_DIR}
/usr/bin/systemctl reboot
