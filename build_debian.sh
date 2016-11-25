#!/bin/bash
## This script is to automate the preparation for a debian file system, which will be used for
## an ONIE installer image.
##
## USAGE:
##   ./build_debian USERNAME PASSWORD_ENCRYPTED
## PARAMETERS:
##   USERNAME
##          The name of the default admin user
##   PASSWORD_ENCRYPTED
##          The encrypted password, expected by chpasswd command

## Default user
USERNAME=$1
[ -n "$USERNAME" ] || {
    echo "Error: no or empty USERNAME argument"
    exit 1
}

## Password for the default user, customizable by environment variable
## By default it is an empty password
## You may get a crypted password by: perl -e 'print crypt("YourPaSsWoRd", "salt"),"\n"'
PASSWORD_ENCRYPTED=$2
[ -n "$PASSWORD_ENCRYPTED" ] || {
    echo "Error: no or empty PASSWORD_ENCRYPTED argument"
    exit 1
}

## Include common functions
. functions.sh

## Enable debug output for script
set -x -e

## docker engine version (with platform)
DOCKER_VERSION=1.11.1-0~jessie_amd64

## Working directory to prepare the file system
FILESYSTEM_ROOT=./fsroot
## Hostname for the linux image
HOSTNAME=sonic
DEFAULT_USERINFO="Default admin user,,,"

## Read ONIE image related config file
. ./onie-image.conf
[ -n "$ONIE_IMAGE_PART_SIZE" ] || {
    echo "Error: Invalid ONIE_IMAGE_PART_SIZE in onie image config file"
    exit 1
}
[ -n "$ONIE_INSTALLER_PAYLOAD" ] || {
    echo "Error: Invalid ONIE_INSTALLER_PAYLOAD in onie image config file"
    exit 1
}
[ -n "$FILESYSTEM_SQUASHFS" ] || {
    echo "Error: Invalid FILESYSTEM_SQUASHFS in onie image config file"
    exit 1
}

## Prepare the file system directory
if [[ -d $FILESYSTEM_ROOT ]]; then
    sudo rm -r $FILESYSTEM_ROOT || die "Failed to clean chroot directory"
fi
mkdir -p $FILESYSTEM_ROOT

## Build a basic Debian system by debootstrap
echo '[INFO] Debootstrap...'
sudo debootstrap --variant=minbase --arch amd64 jessie $FILESYSTEM_ROOT http://ftp.us.debian.org/debian

## Config hostname and hosts, otherwise 'sudo ...' will complain 'sudo: unable to resolve host ...'
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '$HOSTNAME' > /etc/hostname"
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '127.0.0.1       $HOSTNAME' >> /etc/hosts"
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c "echo '127.0.0.1       localhost' >> /etc/hosts"

## Config basic fstab
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'echo "proc /proc proc defaults 0 0" >> /etc/fstab'
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'echo "sysfs /sys sysfs defaults 0 0" >> /etc/fstab'

## Note: mounting is necessary to makedev and install linux image
echo '[INFO] Mount all'
## Output all the mounted device for troubleshooting
mount
trap_push 'sudo umount $FILESYSTEM_ROOT/proc || true'
sudo LANG=C chroot $FILESYSTEM_ROOT mount proc /proc -t proc
clean_sys() {
    sudo umount $FILESYSTEM_ROOT/sys/fs/cgroup/*            \
                $FILESYSTEM_ROOT/sys/fs/cgroup              \
                $FILESYSTEM_ROOT/sys || true
}
trap_push clean_sys
sudo LANG=C chroot $FILESYSTEM_ROOT mount sysfs /sys -t sysfs

## Pointing apt to public apt mirrors and getting latest packages, needed for latest security updates
sudo cp files/apt/sources.list $FILESYSTEM_ROOT/etc/apt/
sudo cp files/apt/apt.conf.d/{81norecommends,apt-{clean,gzip-indexes,no-languages}} $FILESYSTEM_ROOT/etc/apt/apt.conf.d/
sudo LANG=C chroot $FILESYSTEM_ROOT bash -c 'apt-mark auto `apt-mark showmanual`'

## Note: set lang to prevent locale warnings in your chroot
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y update
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y upgrade
echo '[INFO] Install packages for building image'
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install makedev psmisc

## Create device files
echo '[INFO] MAKEDEV'
sudo LANG=C chroot $FILESYSTEM_ROOT /bin/bash -c 'cd /dev && MAKEDEV generic'
## Install initramfs-tools and linux kernel
## Note: initramfs-tools recommends depending on busybox, and we really want busybox for
## 1. commands such as touch
## 2. mount supports squashfs
## However, 'dpkg -i' plus 'apt-get install -f' will ignore the recommended dependency. So
## we install busybox explicitly
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install busybox
echo '[INFO] Install SONiC linux kernel image'
## Note: duplicate apt-get command to ensure every line return zero
sudo dpkg --root=$FILESYSTEM_ROOT -i deps/initramfs-tools_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i deps/linux-image-3.16.0-4-amd64_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f

## Update initramfs for booting with squashfs+aufs
cat files/initramfs-tools/modules | sudo tee -a $FILESYSTEM_ROOT/etc/initramfs-tools/modules > /dev/null

## Hook into initramfs: after partition mount and loop file mount
## 1. Prepare layered file system
## 2. Bind-mount docker working directory (docker aufs cannot work over aufs rootfs)
sudo cp files/initramfs-tools/union-mount $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/union-mount
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/init-bottom/union-mount
sudo cp files/initramfs-tools/union-fsck $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/union-fsck
sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/union-fsck
sudo chroot $FILESYSTEM_ROOT update-initramfs -u

## Install docker
echo '[INFO] Install docker'
## Install apparmor utils since they're missing and apparmor is enabled in the kernel
## Otherwise Docker will fail to start
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install apparmor
docker_deb_url=https://apt.dockerproject.org/repo/pool/main/d/docker-engine/docker-engine_${DOCKER_VERSION}.deb
docker_deb_temp=`mktemp`
trap_push "rm -f $docker_deb_temp"
wget $docker_deb_url -qO $docker_deb_temp && {                                                  \
    sudo dpkg --root=$FILESYSTEM_ROOT -i $docker_deb_temp ||                                    \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f;   \
}
sudo chroot $FILESYSTEM_ROOT docker version
sudo chroot $FILESYSTEM_ROOT service docker stop
## Add docker config drop-in to select aufs, otherwise it may select other storage driver
sudo mkdir -p $FILESYSTEM_ROOT/etc/systemd/system/docker.service.d/
## Note: $_ means last argument of last command
sudo cp files/docker/docker.service.conf $_

## Create default user
## Note: user should be in the group with the same name, and also in sudo/docker group
sudo LANG=C chroot $FILESYSTEM_ROOT useradd -G sudo,docker $USERNAME -c "$DEFAULT_USERINFO" -m -s /bin/bash
## Create password for the default user
echo $USERNAME:$PASSWORD_ENCRYPTED | sudo LANG=C chroot $FILESYSTEM_ROOT chpasswd -e

## Pre-install hardware drivers
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install      \
    firmware-linux-nonfree

## Pre-install the fundamental packages
## Note: gdisk is needed for sgdisk in install.sh
## Note: parted is needed for partprobe in install.sh
## Note: ca-certificates is needed for easy_install
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get -y install      \
    file                    \
    ifupdown                \
    iproute2                \
    isc-dhcp-client         \
    sudo                    \
    vim                     \
    tcpdump                 \
    ntp                     \
    ntpstat                 \
    openssh-server          \
    python                  \
    python-setuptools       \
    rsyslog                 \
    python-apt              \
    traceroute              \
    iputils-ping            \
    net-tools               \
    bsdmainutils            \
    ca-certificates         \
    i2c-tools               \
    efibootmgr              \
    usbutils                \
    pciutils

## Remove sshd host keys, and will regenerate on first sshd start
sudo rm -f $FILESYSTEM_ROOT/etc/ssh/ssh_host_*_key*
sudo cp files/sshd/host-ssh-keygen.sh $FILESYSTEM_ROOT/usr/local/bin/
sudo cp -f files/sshd/sshd.service $FILESYSTEM_ROOT/lib/systemd/system/ssh.service
## Config sshd
sudo augtool --autosave "set /files/etc/ssh/sshd_config/UseDNS no" -r $FILESYSTEM_ROOT

## Config sysctl
sudo mkdir -p $FILESYSTEM_ROOT/var/core
sudo augtool --autosave "
set /files/etc/sysctl.conf/kernel.core_pattern '|/usr/bin/coredump-compress %e %p'

set /files/etc/sysctl.conf/net.ipv4.conf.default.forwarding 1
set /files/etc/sysctl.conf/net.ipv4.conf.all.forwarding 1
set /files/etc/sysctl.conf/net.ipv4.conf.eth0.forwarding 0

set /files/etc/sysctl.conf/net.ipv4.conf.default.arp_accept 0
set /files/etc/sysctl.conf/net.ipv4.conf.default.arp_announce 0
set /files/etc/sysctl.conf/net.ipv4.conf.default.arp_filter 0
set /files/etc/sysctl.conf/net.ipv4.conf.default.arp_notify 0
set /files/etc/sysctl.conf/net.ipv4.conf.default.arp_ignore 0
set /files/etc/sysctl.conf/net.ipv4.conf.all.arp_accept 0
set /files/etc/sysctl.conf/net.ipv4.conf.all.arp_announce 1
set /files/etc/sysctl.conf/net.ipv4.conf.all.arp_filter 0
set /files/etc/sysctl.conf/net.ipv4.conf.all.arp_notify 1
set /files/etc/sysctl.conf/net.ipv4.conf.all.arp_ignore 2

set /files/etc/sysctl.conf/net.ipv6.conf.default.forwarding 1
set /files/etc/sysctl.conf/net.ipv6.conf.all.forwarding 1
set /files/etc/sysctl.conf/net.ipv6.conf.eth0.forwarding 0

set /files/etc/sysctl.conf/net.ipv6.conf.default.accept_dad 0
set /files/etc/sysctl.conf/net.ipv6.conf.all.accept_dad 0
" -r $FILESYSTEM_ROOT

## docker-py is needed by Ansible docker module
sudo LANG=C chroot $FILESYSTEM_ROOT easy_install pip
sudo LANG=C chroot $FILESYSTEM_ROOT pip install 'docker-py==1.6.0'
## Remove pip which is unnecessary in the base image
sudo LANG=C chroot $FILESYSTEM_ROOT pip uninstall -y pip

## Config DHCP for eth0
sudo tee -a $FILESYSTEM_ROOT/etc/network/interfaces > /dev/null <<EOF

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

sudo cp files/dhcp/rfc3442-classless-routes $FILESYSTEM_ROOT/etc/dhcp/dhclient-exit-hooks.d

## Clean up apt
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get autoremove
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get autoclean
sudo LANG=C chroot $FILESYSTEM_ROOT apt-get clean
sudo LANG=C chroot $FILESYSTEM_ROOT bash -c 'rm -rf /usr/share/doc/* /usr/share/locale/* /var/lib/apt/lists/* /tmp/*'

## Umount all
echo '[INFO] Umount all'
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -km /sys || true
sudo LANG=C chroot $FILESYSTEM_ROOT umount -lf /sys
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -km /proc || true
sudo LANG=C chroot $FILESYSTEM_ROOT umount /proc

## Prepare empty directory to trigger mount move in initramfs-tools/mount_loop_root, implemented by patching
sudo mkdir $FILESYSTEM_ROOT/host

## Compress most file system into squashfs file
sudo rm -f $ONIE_INSTALLER_PAYLOAD $FILESYSTEM_SQUASHFS
## Output the file system total size for diag purpose
sudo du -hs $FILESYSTEM_ROOT
sudo mksquashfs $FILESYSTEM_ROOT $FILESYSTEM_SQUASHFS -e boot -e var/lib/docker

## Compress together with /boot and /var/lib/docker as an installer payload zip file
pushd $FILESYSTEM_ROOT && sudo zip $OLDPWD/$ONIE_INSTALLER_PAYLOAD -r boot/ -r var/lib/docker; popd
sudo zip -g $ONIE_INSTALLER_PAYLOAD $FILESYSTEM_SQUASHFS
