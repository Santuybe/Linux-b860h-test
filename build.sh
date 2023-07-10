#!/bin/bash

OUT_FILENAME="manjaroLinuxARM-aarch64_S905X"

ROOTFS_TYPE="ext4"

SKIP_SIZE="68"
BOOT_SIZE="256"
ROOT_SIZE="1536"
IMG_SIZE="$((SKIP_SIZE + BOOT_SIZE + ROOT_SIZE))"

BOOT_LABEL="BOOT"
ROOT_LABEL="ROOT"

IMG_FILENAME="${OUT_FILENAME}.img"
WORKING_DIR="/WORKING_DIR"
MANJAROLINUXARM_TARBALL_FILE="${WORKING_DIR}/Manjaro-ARM-aarch64-latest.tar.gz"
OUT_DIR="${WORKING_DIR}/BUILD_OUT"
BOOT_FILES="${WORKING_DIR}/src/boot-files"
PATCH_FILES="${WORKING_DIR}/src/patch"


# Create IMG file

print_err() {
  echo -e "${1}"
  exit 1
}

print_msg() {
  echo -e "${1}"
}

make_image() {
  mkdir -p ${OUT_DIR}
  dd if=/dev/zero of=${IMG_FILENAME} bs=1M count=${IMG_SIZE} conv=fsync >/dev/null 2>&1
  sync

  print_msg "[1/5] Setup IMG File"
  parted -s ${IMG_FILENAME} mklabel msdos 2>/dev/null
  parted -s ${IMG_FILENAME} mkpart primary fat32 $((SKIP_SIZE))MiB $((SKIP_SIZE + BOOT_SIZE - 1))MiB 2>/dev/null
  parted -s ${IMG_FILENAME} mkpart primary ${ROOTFS_TYPE} $((SKIP_SIZE + BOOT_SIZE))MiB 100% 2>/dev/null
  sync

  LOOP_DEV="$(losetup -P -f --show "${IMG_FILENAME}")"
  [[ -n "${LOOP_DEV}" ]] || echo "losetup ${IMG_FILENAME} failed."

  mkfs.vfat -n ${BOOT_LABEL} ${LOOP_DEV}p1 >/dev/null 2>&1

  if [[ "${ROOTFS_TYPE}" == "btrfs" ]]; then
    mkfs.btrfs -f -L ${ROOT_LABEL} -m single ${LOOP_DEV}p2 >/dev/null 2>&1
  else
    mkfs.ext4 -O ^metadata_csum,^64bit -F -q -L ${ROOT_LABEL} -m 0 ${LOOP_DEV}p2 >/dev/null 2>&1
  fi

  # TODO: Write device bootloader

  mkdir -p mnt && sync

  print_msg "[2/5] Mounting IMG File"
  if ! mount ${LOOP_DEV}p2 mnt; then
    # fdisk -l
    print_err "mount ${LOOP_DEV}p2 failed!"
  fi

  mkdir -p mnt/boot && sync

  if ! mount ${LOOP_DEV}p1 mnt/boot; then
    # fdisk -l
    print_err "mount ${LOOP_DEV}p1 failed!"
  fi

  print_msg "[3/5] Copying files"
  cp -af ${BOOT_FILES}/* mnt/boot
  bsdtar -xpf ${MANJAROLINUXARM_TARBALL_FILE} -C mnt
  cp -af ${PATCH_FILES}/* mnt/
  [ -f ${WORKING_DIR}/lscolors.sh ] && cp ${WORKING_DIR}/lscolors.sh mnt/etc && chmod +x mnt/etc/lscolors.sh

  cat mnt/etc/_bashrc >> mnt/etc/bash.bashrc && rm mnt/etc/_bashrc

  # Modify mkinitcpio
  sed -i "s/PRESETS=.*/PRESETS=('default')/" mnt/etc/mkinitcpio.d/linux-aarch64.preset
  sed -i 's/ALL_kver=.*/ALL_kver="\/boot\/Image"/' mnt/etc/mkinitcpio.d/linux-aarch64.preset
  sed -i '/^[^#]/ s/\(^fallback_.*$\)/#\1/' mnt/etc/mkinitcpio.d/linux-aarch64.preset

  # cleaning up
  rm mnt/boot/{Image.gz,initramfs-linux-fallback.img}
  find ./mnt/boot/dtbs -mindepth 1 ! -regex '^./mnt/boot/dtbs/amlogic\(/.*\)?' -delete

  print_msg "[4/5] Setup Boot Files"
  mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "S905 autoscript" -d mnt/boot/s905_autoscript.cmd mnt/boot/s905_autoscript 2>/dev/null
  mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "eMMC autoscript" -d mnt/boot/emmc_autoscript.cmd mnt/boot/emmc_autoscript 2>/dev/null
  mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "AML autoscript" -d mnt/boot/aml_autoscript.txt mnt/boot/aml_autoscript 2>/dev/null
  rm mnt/boot/*.cmd
  #mkimage -n "uInitrd Image" -A arm64 -O linux -T ramdisk -C none -d mnt/boot/initramfs-linux.img mnt/boot/uInitrd 2>/dev/null
  #mkimage -n "uImage" -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 -d mnt/boot/Image mnt/boot/uImage 2>/dev/null
  sync

  umount -R -f mnt 2>/dev/null
  losetup -d ${LOOP_DEV} 2>/dev/null

  print_msg "[5/5] Compress IMG File"
  xz -9 ${IMG_FILENAME} && mv "${IMG_FILENAME}.xz" ${OUT_DIR}
}

cd ${WORKING_DIR}

make_image
