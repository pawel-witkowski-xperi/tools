#!/bin/bash

set -e

if [[ $# -ne 2 ]]; then
  echo "Usage: downloader.sh DEVICE_IP FIRMWARE_URL" >&2
  exit 1
fi

DEVICE_IP=$1
FIRMWARE_URL=$2

PYVENV=".venv"
ARTIFACTORY="https://repo-vip.tivo.com/artifactory/api/pypi/pypi/simple"
TEMP_DIR=$(mktemp -d)
EXEC_PATH="/testing"

SW_UPDATE_PACKAGE_INSTALL="sw-updater-package-install"
SW_UPDATE_PACKAGE_INSTALL_BIN="sw-updater-package-install.bin"
SW_UPDATE_PKG="$(basename -s .tar.gz $FIRMWARE_URL).pkg"
TAR_NAME="$(basename $FIRMWARE_URL)"

if [[ ! -d "$PYVENV"  ]]; then
  python3 -m venv $PYVENV
  source $PYVENV/bin/activate
  pip3 install fget --index=https://repo-vip.tivo.com/artifactory/api/pypi/pypi/simpleo
else
  source $PYVENV/bin/activate
fi

function cleanup() {
  rm -rf "$TEMP_DIR"
  echo "[rm] $TEMP_DIR"
}

function download_package() {
  echo "[download] Downloading $TAR_NAME"
  # fget bug: does not allow directory in --destination param
  python3 -m fget --url $FIRMWARE_URL --destination $TEMP_DIR/$TAR_NAME
  echo "[download] Done"
}

function untar_package() {
  echo "[untar] Unpacking $TAR_NAME"
  tar -xf "$TEMP_DIR/$TAR_NAME" -C $TEMP_DIR
  echo "[untar] Done"
}

function upload_files() {
  echo "[upload] Uploading $SW_UPDATE_PACKAGE_INSTALL $SW_UPDATE_PACKAGE_INSTALL_BIN $SW_UPDATE_PKG"
  scp "$TEMP_DIR/$SW_UPDATE_PACKAGE_INSTALL" "$TEMP_DIR/$SW_UPDATE_PACKAGE_INSTALL_BIN" "$TEMP_DIR/$SW_UPDATE_PKG" "root@$DEVICE_IP:$EXEC_PATH"
  echo "[upload] Done"
}

function flash_device() {
  echo "[flash] Flashing $DEVICE_IP"
  ssh "root@$DEVICE_IP" "$EXEC_PATH/$SW_UPDATE_PACKAGE_INSTALL" "$EXEC_PATH/$SW_UPDATE_PKG"
  echo "[flash] Done"
}

function remove_temporary_files() {
  echo "[cleaning] Cleaning temporary files in $EXEC_PATH on $DEVICE_IP"
  ssh "root@$DEVICE_IP" "rm -rf $EXEC_PATH/$SW_UPDATE_PACKAGE_INSTALL" "$EXEC_PATH/$SW_UPDATE_PACKAGE_INSTALL_BIN" "$EXEC_PATH/$SW_UPDATE_PKG"
  echo "[cleaning] Done"
}

function set_uenv() {
  echo "[config] Setting uenvs on $DEVICE_IP"
  ssh "root@$DEVICE_IP" "uenv set powermode on"
  ssh "root@$DEVICE_IP" "uenv set factory-reset 1"
  sleep 2
  echo "[config] Done"
}

function reboot_device() {
  echo "[reboot] Calling device reboot in 3..."
  sleep 1
  echo "[reboot] Calling device reboot in 2..."
  sleep 1
  echo "[reboot] Calling device reboot in 1..."
  sleep 1
  ssh "root@$DEVICE_IP" "/sbin/reboot"

}

trap cleanup EXIT TERM INT

download_package
untar_package
upload_files
flash_device
remove_temporary_files
set_uenv
reboot_device
