#!/bin/bash

# Toolchain direct download:
# https://occ-oss-prod.oss-cn-hangzhou.aliyuncs.com/resource//1721095219235/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V2.10.1-20240712.tar.gz
# mkdir -p /opt/toolchain
# tar -zxvf Xuantie-*.tar.gz -C /opt/toolchain
# make CONF=k230_canmv_defconfig

set -e

IMG=out/milkv-duos-musl-riscv64-sd_2024-1124-1157.img
DEV=sdb
PART=3
DEFAULT_PASSWORD="mv"

if [ "$EUID" -ne 0 ]; then
	echo "Run as root"
	exit
fi

dd if=$IMG of=/dev/$DEV bs=1M; sync
expect <<EOF
spawn parted /dev/$DEV
expect "(parted)"
send "resizepart\n"
expect "Partition number?"
send "$PART\n"
expect "End?"
send "16GB\n"
expect "(parted)"
send "quit\n"
EOF

e2fsck -f /dev/$DEV$PART
resize2fs /dev/$DEV$PART

# Stage Debian bootstrap into container
run_debootstrap=$(cat << EOF
mkdir -p /mnt/root /mnt/debroot
debootstrap --arch=riscv64 \
	--include="network-manager,build-essential,dkms,python3-spidev,wget,zip,device-tree-compiler,ssh,u-boot-tools,nano,less,dbus,systemd-timesyncd,ca-certificates,rsync,build-essential" \
	unstable /mnt/debroot
EOF
)

# Copy and configure Debian bootstrap
copy_debootstrap=$(cat << EOF
set -e

mount /dev/$DEV$PART /mnt/root

# Copy bootstrap
rm -rf /mnt/root/sbin /mnt/root/bin
set +e
rsync -av --exclude="/mnt/debroot/bin" --exclude="/mnt/debroot/lib" /mnt/debroot/ /mnt/root/
rsync -av /mnt/debroot/bin/ /mnt/root/bin/
rsync -av /mnt/debroot/lib/ /mnt/root/lib/
set -e

# Remove legacy /etc/init.d scripts except for driver loader
mv /mnt/root/etc/init.d /mnt/root/root/
mkdir -p /mnt/root/etc/init.d/
cp /mnt/root/root/init.d/S99user /mnt/root/etc/init.d/

# Driver loader shim
cat > /mnt/root/etc/systemd/system/duo-init.service << EOF2
[Unit]
Description=Duo initialization
After=local-fs.target

[Service]
Type=forking
ExecStart=/etc/init.d/S99user start
ExecStop=/etc/init.d/S99user stop
ExecReload=/etc/init.d/S99user restart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

# Create binds
mount -o bind /dev /mnt/root/dev
mount -o bind /proc /mnt/root/proc
mount -o bind /sys /mnt/root/sys

# Configure in chroot
chroot /mnt/root /bin/bash -c ' \
	systemctl enable systemd-timesyncd; timedatectl set-ntp true; \
	systemctl enable duo-init.service; \
	echo \"ca-certificates ca-certificates/activate_on_install boolean true\" | debconf-set-selections; \
	dpkg-reconfigure -f noninteractive ca-certificates; \
	update-ca-certificates; \
	echo "$DEFAULT_PASSWORD" | passwd '\$1' --stdin'

ln -sf /dev/null /mnt/root/etc/systemd/system/serial-getty@hvc0.service

umount /mnt/root
EOF
)

# For faster iteration, start debootstrap container and run debootstrap command, then docker commit
if docker image ls debootstrap-loaded | grep -q 'latest'; then

	echo "$copy_debootstrap; exit" \
		| docker run -it --rm --device=/dev/$DEV$PART --name debootstrap --privileged \
			debootstrap-loaded:latest /bin/bash
fi

else

	docker build -f debootstrap.Dockerfile -t debootstrap
	echo "$run_debootstrap; $copy_debootstrap; exit" \
		| docker run -it --rm --device=/dev/$DEV$PART --name debootstrap --privileged \
			debootstrap:latest /bin/bash
fi

