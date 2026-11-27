#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
SRC_DIR="${REPO_DIR}/src"
KREL="$(uname -r)"
UPDATES_DIR="/usr/lib/modules/${KREL}/updates"
BUILD_DIR="/tmp/rtw8723de-fix-build"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing patched modules from ${UPDATES_DIR}..."
    for mod in btusb btrtl btmtk btintel btbcm rtw88_core rtw88_pci; do sudo rm -f "${UPDATES_DIR}/${mod}.ko"; done
    sudo depmod -a
    echo "Done. Stock kernel modules restored."
    exit 0
fi

KSERIES="$(echo "${KREL}" | cut -d'.' -f1,2)"
if [[ "${KSERIES}" != "7.2" && "${KSERIES}" != "7.3" ]]; then
    echo "Warning: Bundled src/ is based on Linux 7.2.15, but you are running ${KREL}."
    echo "If compilation fails, apply rtw8723de-btusb-shutdown.patch to your kernel source instead."
    read -rp "Continue anyway? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || exit 1
fi

if [[ ! -d "${SRC_DIR}" && -f "${REPO_DIR}/src.zip" ]]; then
    unzip -q "${REPO_DIR}/src.zip" -d "${REPO_DIR}"
fi

if [[ ! -d "${SRC_DIR}" ]]; then
    echo "Error: Source folder not found at ${SRC_DIR}"
    exit 1
fi

if [[ ! -d "/usr/lib/modules/${KREL}/build" ]]; then
    echo "Error: Kernel headers for ${KREL} not found."
    echo "See REQUIREMENTS.txt for the install command for your distro."
    exit 1
fi

echo "==> Copying patched driver source into temporary build workspace..."
rm -rf "${BUILD_DIR}"
cp -r "${SRC_DIR}" "${BUILD_DIR}"

echo "==> Compiling Bluetooth and rtw88 PCI kernel modules for ${KREL}..."
make -C "/usr/lib/modules/${KREL}/build" M="${BUILD_DIR}/drivers/bluetooth" modules
make -C "/usr/lib/modules/${KREL}/build" M="${BUILD_DIR}/drivers/net/wireless/realtek/rtw88" modules

echo "==> Installing patched modules to ${UPDATES_DIR}..."
sudo mkdir -p "${UPDATES_DIR}"
sudo cp "${BUILD_DIR}/drivers/bluetooth/"{btusb,btrtl,btmtk,btintel,btbcm}.ko "${UPDATES_DIR}/"
sudo cp "${BUILD_DIR}/drivers/net/wireless/realtek/rtw88/"{rtw88_core,rtw88_pci}.ko "${UPDATES_DIR}/"
sudo depmod -a

rm -rf "${BUILD_DIR}"
echo ""
echo "Success! Perform one full shutdown (power off completely) and power back on."
echo "To remove later, run: ./install.sh --uninstall"
