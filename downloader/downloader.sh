#!/bin/bash

set -e

function show_help() {
  echo "Tool to download and install or simply install given firmware on a device. Usage: "
  echo "--device-ip         IP of a device under flash, e.g. --device-ip=192.168.0.1"
  echo "--firmware-tar     Skip download and simply install the firmware defined by this variable,
                            e.g. --firmware-tar=/mnt/packages/tivo-os-image-18.847.0-ng-dev-aml-t962d4-cvte-xperi.tar.gz"
  echo "--firmware-url      URL to be downloaded and installed, if it's specified then
                            --firmware-tar param is omitted, 
                            e.g. --firmware-url=https://builds.corp.vewd.com/yocto/tv-master/2025-09-08-18.847.0/xperi/cvte/aml-t962d4-dev/tivo-os-image-18.847.0-ng-dev-aml-t962d4-cvte-xperi.tar.gz"
  echo "--branch            If --firmware-url is not specified, this is the branch to
                            be used by the fget downloader, e.g. --branch=tv-master"
  echo "--build             If --firmware-url is not specified, this is the build to
                            be used by the fget downloader, e.g. --build=latest, --build=18.848.0"
  echo "--customer          If --firmware-url is not specified, this is the customer to
                            be used by the fget downloader, e.g. --customer=xperi"
  echo "--sdk               If --firmware-url is not specified and there are multiple yocto versions
                            available for given customer, this switch is used to specify the 
                            used one, e.g. --sdk=4-0. Allowed values: 3-1 and 4-0. Default 3-1."
  echo "--motherboard       If --firmware-url is not specified, this is the motherboard variant to
                            be used by the fget downloader, e.g. --motherboard=cvte"
  echo "--platform          If --firmware-url is not specified, this is the platform to
                            be used by the fget downloader, e.g. --platform=aml-t962d4"
}

DEVICE_IP=""
FIRMWARE_URL=""
FIRMWARE_TAR=""
BRANCH=""
BUILD=""
CUSTOMER=""
SDK=""
MOTHERBOARD=""
PLATFORM=""

TEMP_DIR=$(mktemp -d)
EXEC_PATH="/testing"

SW_UPDATE_PACKAGE_INSTALL="sw-updater-package-install"
SW_UPDATE_PACKAGE_INSTALL_BIN="sw-updater-package-install.bin"
SW_UPDATE_PKG=""
TAR_NAME="firmware.tar.gz"

for arg do
  shift
  case "${arg}" in
    --help) show_help; exit 0;;
    --device-ip=*) DEVICE_IP="${arg#--device-ip=}";continue;;
    --firmware-tar=*) FIRMWARE_TAR="${arg#--firmware-tar=}";continue;;
    --firmware-url=*) FIRMWARE_URL="${arg#--firmware-url=}";continue;;
    --branch=*) BRANCH="${arg#--branch=}";continue;;
    --build=*) BUILD="${arg#--build=}";continue;;
    --customer=*) CUSTOMER="${arg#--customer=}";continue;;
    --sdk=*) SDK="${arg#--sdk=}";continue;;
    --motherboard=*) MOTHERBOARD="${arg#--motherboard=}";continue;;
    --platform=*) PLATFORM="${arg#--platform=}";continue;;
  esac
done

if [[ -z "$DEVICE_IP" ]]; then
  echo "Please specify the device"
  exit 1
fi



SCRIPT_DIR=$(dirname $0)
PYVENV=".venv"
ARTIFACTORY="https://repo-vip.tivo.com/artifactory/api/pypi/pypi/simple"
if [[ ! -d "$SCRIPT_DIR/$PYVENV"  ]]; then
  if dpkg -s "python3-venv" &> "/dev/null"; then
    echo "python3-venv is available"
  else
    echo "python3-venv is required. Please run 'sudo apt install python3-venv'"
    exit 1
  fi
  python3 -m venv $PYVENV
  source $SCRIPT_DIR/$PYVENV/bin/activate
  pip3 install fget --index=$ARTIFACTORY
else
  source $SCRIPT_DIR/$PYVENV/bin/activate
fi

function cleanup() {
  rm -rf "$TEMP_DIR"
  echo "[rm] $TEMP_DIR"
}

function print_fw() {
  echo "[setup] Print device state before flashing"
  ssh "root@$DEVICE_IP" "cat /etc/os-release"
  echo "[setup] Done"
}

function download_package() {
  echo "[download] Downloading package..."
  # fget bug: does not allow directory in --destination param
  FIRMWARE_TAR="$TEMP_DIR/$TAR_NAME"
  if [[ -n "$FIRMWARE_URL" ]]; then
    python3 -m fget --url "$FIRMWARE_URL" --destination "$FIRMWARE_TAR"
  else
    CUSTOMER_ELEMENT=""
    if [[ -z "$SDK" || "$SDK" -eq "3-1" ]]; then
      CUSTOMER_ELEMENT="$CUSTOMER"
    else
      CUSTOMER_ELEMENT="$CUSTOMER-$SDK"
    fi
    BOARD_ELEMENT="$PLATFORM*-dev"
    ARCHIVE_ELEMENT="$CUSTOMER.tar.gz"
    python3 -m fget --url_elements yocto "$BRANCH" "$BUILD" "$CUSTOMER_ELEMENT" "$MOTHERBOARD" "$BOARD_ELEMENT" "$ARCHIVE_ELEMENT" --destination "$FIRMWARE_TAR"
  fi
  echo "[download] Done"
}

function untar_package() {
  echo "[untar] Unpacking $FIRMWARE_TAR"
  tar -xf "$FIRMWARE_TAR" -C "$TEMP_DIR"
  SW_UPDATE_PKG=$(basename $(find $TEMP_DIR -type f -name "*.pkg"))
  echo "[untar] Done"
}

function upload_files() {
  echo "[upload] Uploading $SW_UPDATE_PACKAGE_INSTALL $SW_UPDATE_PACKAGE_INSTALL_BIN $SW_UPDATE_PKG"
  scp "$TEMP_DIR/$SW_UPDATE_PACKAGE_INSTALL" "$TEMP_DIR/$SW_UPDATE_PKG" "root@$DEVICE_IP:$EXEC_PATH"
  if [[ -f "$TEMP_DIR/$SW_UPDATE_PACKAGE_INSTALL_BIN" ]]; then
    scp "$TEMP_DIR/$SW_UPDATE_PACKAGE_INSTALL_BIN" "root@$DEVICE_IP:$EXEC_PATH"
  fi
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

print_fw
if [[ -z "$FIRMWARE_TAR" ]]; then
  download_package
fi
untar_package
upload_files
flash_device
remove_temporary_files
set_uenv
reboot_device
