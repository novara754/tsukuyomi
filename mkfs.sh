set -xe

if [ -z $LIMINE_SYS ]; then
	echo "LIMINE_SYS not set"
	exit 1
fi

# Create empty 128 MB file
dd if=/dev/zero of=hdd.img bs=1024 count=$((128 * 1024 * 1024 / 1024))

# Create one 16 MB EFI partition for booting
# and one partition for storage filling the rest of the drive.
sgdisk hdd.img \
	-n 1::+16M -t 1:ef00 -c 1:ESP \
	-n 2::+96M -t 2:8300 -c 2:FILESYSTEM \
	-p

# Install limine bootsector
limine bios-install hdd.img

sudo losetup /dev/loop0 hdd.img --offset $((1 * 1024 * 1024)) --sizelimit $((16 * 1024 * 1024))
sudo mkfs.fat -v -F 16 /dev/loop0
mkdir -p hdd_esp
sudo mount /dev/loop0 hdd_esp
sudo mkdir -p hdd_esp/EFI/BOOT
sudo mkdir -p hdd_esp/boot/limine
sudo cp limine.conf $LIMINE_SYS hdd_esp/boot/limine
sudo cp $LIMINE_BOOTX64 hdd_esp/EFI/BOOT
sudo umount hdd_esp
sudo losetup --detach /dev/loop0

# sudo losetup /dev/loop1 hdd.img --offset $((17 * 1024 * 1024)) --sizelimit $((96 * 1024 * 1024))
# sudo mkfs.ext2 /dev/loop1
# mkdir -p hdd_filesystem
# sudo mount /dev/loop1 hdd_filesystem
# sudo chown $(whoami) hdd_filesystem
# echo "hello, world." > hdd_filesystem/hello.txt
# sudo umount hdd_filesystem
# sudo losetup --detach /dev/loop1
