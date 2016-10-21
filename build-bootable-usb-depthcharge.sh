#!/bin/bash

# Copyright 2015 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script produces a bootable USB drive, designed to boot using verified
# boot.

# Because this script does things like sgdisk, mount, etc. you must be root,
# so don't get the wrong command line parameters! <- super serious

set -e
shopt -s extglob

# Convenience function for ending the script with some output.
trap "exit 99" USR2
TOP_PID=$$

function die() {
  echo "$*" >& 2
  kill -USR2 $TOP_PID
}

# Function to attempt unmounting a mount point up to three times, sleeping
# a couple of seconds between attempts.
function umount_retry() {
  set +e
  TRIES=0
  while (! umount $1); do
    ((TRIES++))
    [[ ${TRIES} > 2 ]] && die "Unable to umount $0"
    sleep 2
  done
  set -e
}

function usage() {
  echo "$0 [block device] [root directory]"
}

is_usb() {
  if [ -n "$(type -path udevadm)" ]; then
    udevadm info --query=all --name="${BLOCK_DEVICE}" | grep -q ID_BUS=usb
   else
    # For a usb device on the pixel2 we expect to see something like:
    # /sys/devices/pci0000:00/0000:00:14.0/usb2/2-2/2-2:1.0/host5/target5:0:0/5:0:0:0
    (cd /sys/block/$(basename "${BLOCK_DEVICE}")/device 2>/dev/null && pwd -P) | grep -q usb
  fi
}


# Absolute path of where this script is stored.
SCRIPT_DIR=$( cd $( dirname "${BASH_SOURCE[0]}" ) && pwd)
PATH="${SCRIPT_DIR}/../buildtools/toolchain/:${PATH}"
VB_DIR="${SCRIPT_DIR}/../third_party/vboot_reference"
DC_DIR="${SCRIPT_DIR}/../third_party/depthcharge"
MX_DIR="${SCRIPT_DIR}/../magenta"

# Grab some arguments, do some basic validation.
[[ $# -eq 2 ]] || (usage; die)
[[ -b "$1" ]] || (usage; die "$1 is not a block device")
[[ -d "$2" ]] || (usage; die "$2 is not a directory")
BLOCK_DEVICE=$1
ROOT_DIR=$2

KERNEL_IMAGE="$(mktemp)"
trap "rm -rf \"${KERNEL_IMAGE}\"" INT TERM EXIT

# Do a sanity check on the block device: help prevent users from accidentally
# destroying their workstations by checking whether this is a usb drive.
if ! is_usb; then
  die "${BLOCK_DEVICE} is not a usb drive"
fi

# Destroy any existing GPT/MBR on the device.  We're going to use cgpt soon and
# it doesn't seem to properly wipe existing partitions.
sgdisk --zap-all "${BLOCK_DEVICE}"

make -C "${VB_DIR}" cgpt futil

PATH="${PATH}:${VB_DIR}/build/futility" \
    BUILD_IMAGE_PATH="${VB_DIR}/tests/devkeys" \
    VB_SOURCE="${VB_DIR}" make -j8 -C "${DC_DIR}" uefi

"${VB_DIR}"/build/futility/futility vbutil_kernel \
	--pack "${KERNEL_IMAGE}"  \
	--keyblock "${VB_DIR}"/tests/devkeys/recovery_kernel.keyblock \
	--signprivate \
		"${VB_DIR}"/tests/devkeys/recovery_kernel_data_key.vbprivk \
	--version 1 \
	--config "${SCRIPT_DIR}"/onechar.txt \
	--bootloader "${SCRIPT_DIR}"/onechar.txt \
	--vmlinuz "${MX_DIR}"/build-magenta-pc-x86-64/magenta.bin

CGPT="${VB_DIR}/build/cgpt/cgpt"

# The size of the first two partitions (kernel, root) don't vary per-device.
"${CGPT}" create "${BLOCK_DEVICE}"
"${CGPT}" add -s 32768 -t kernel -b 64 -l kernel "${BLOCK_DEVICE}"
"${CGPT}" add -s 4194304 -t rootfs -b 32832 -l root "${BLOCK_DEVICE}"
"${CGPT}" add -i 1 -T 1 -S 1 -P 2 "${BLOCK_DEVICE}"
"${CGPT}" add -i 4 -s 131072 -t efi -b 4227136 -l efi "${BLOCK_DEVICE}"

# Use sgdisk to make the data partition so we don't have to calculate the size.
sgdisk -N3 -c3:data -t3:0700 "${BLOCK_DEVICE}"

# Copy kernel to the kernel partition.
dd if="${KERNEL_IMAGE}" of="${BLOCK_DEVICE}1"

# Clean up the temporary kernel image.
rm -rf "${KERNEL_IMAGE}"

# Format the other two partitions.
mkfs.ext4 "${BLOCK_DEVICE}2"
mkfs.ext4 "${BLOCK_DEVICE}3"

mkfs.vfat -F 32 "${BLOCK_DEVICE}4"

# Mount the root partition, trap the unmount.
MOUNT_POINT="$(mktemp -d)"
mount "${BLOCK_DEVICE}2" "$MOUNT_POINT"
trap "umount_retry \"${MOUNT_POINT}\" && rm -rf \"${MOUNT_POINT}\"" INT TERM EXIT

# Make everything owned by root.
chown -R root:root "${MOUNT_POINT}"/*

# Unmount the root partition (might as well reuse the mount point).
umount_retry "${MOUNT_POINT}"

# Copy data to the data partition.
mount "${BLOCK_DEVICE}3" "${MOUNT_POINT}"
cp -a "${ROOT_DIR}"/* "${MOUNT_POINT}"
chown -R root:root "${MOUNT_POINT}"/*
umount_retry "${MOUNT_POINT}"

# Copy depthcharge to the EFI partition (and just let the trap unmount us).
mount "${BLOCK_DEVICE}4" "${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}"/efi/boot
mkdir -p "${MOUNT_POINT}"/depthcharge
cp "${DC_DIR}"/build/uefi/image/uefi_dev.efi \
    "${MOUNT_POINT}"/efi/boot/bootx64.efi
cp "${DC_DIR}"/build/uefi/image/uefi_dev.rwa.bin \
    "${MOUNT_POINT}"/depthcharge/rwa
cp "${DC_DIR}"/build/uefi/image/uefi_dev.rwb.bin \
    "${MOUNT_POINT}"/depthcharge/rwb
