# Manual Patching Guide for Future Linux Kernels

If a future Linux kernel (e.g., `7.4+` or `8.0+`) changes surrounding code so the bundled `src/` folder no longer compiles via `./install.sh`, use this guide to apply the exact same fix to your own kernel's source code.

---

## Step 1: Install Kernel Headers & Build Tools

Install matching headers and compiler tools for your running kernel (see `REQUIREMENTS.txt` for distro-specific commands).

---

## Step 2: Download Your Running Kernel's Driver Source

Clone only the two affected driver folders (`drivers/bluetooth` and `drivers/net/wireless/realtek/rtw88`) matching your current kernel version (`uname -r`):

```bash
KVER=$(uname -r | cut -d'-' -f1)
REPO_URL="https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux.git"

git clone --depth 1 --filter=blob:none --sparse -b "v${KVER}" "${REPO_URL}" linux-rtw-fix
cd linux-rtw-fix
git sparse-checkout set drivers/bluetooth drivers/net/wireless/realtek/rtw88
```

---

## Step 3: Apply the Fix (Automatic or Manual)

### Option A: Apply the `.patch` File Automatically
```bash
git apply /path/to/rtw8723de-btusb-shutdown.patch
```

### Option B: Apply the Code Edits Manually (If Line Numbers Shifted)
If `git apply` fails because surrounding lines changed in a newer kernel, open the two files below and make these exact edits:

#### 1. `drivers/bluetooth/btusb.c`
* **Find the `#define BTUSB_*` flag list** (around line 990) and add a new flag bit at the bottom:
  ```c
  #define BTUSB_NEEDS_SHUTDOWN_RESET	20
  ```
* **Find `btusb_open(struct hci_dev *hdev)`** (around line 2045) right after `data->intf->needs_remote_wakeup = 1;` and add:
  ```c
  set_bit(BTUSB_NEEDS_SHUTDOWN_RESET, &data->flags);
  ```
* **Find `static struct usb_driver btusb_driver`** (near the end of the file, around line 4810). Add `btusb_shutdown()` right above it, and register `.shutdown = btusb_shutdown,` inside `btusb_driver`:
  ```c
  static void btusb_shutdown(struct usb_interface *intf)
  {
  	struct btusb_data *data = usb_get_intfdata(intf);
  	struct hci_dev *hdev;
  	int err = -1;

  	if (!data || intf != data->intf)
  		return;

  	hdev = data->hdev;
  	data->intf->needs_remote_wakeup = 0;
  	data->udev->do_remote_wakeup = 0;

  	if (test_and_clear_bit(BTUSB_NEEDS_SHUTDOWN_RESET, &data->flags) &&
  	    hdev->shutdown) {
  		err = usb_autopm_get_interface(data->intf);
  		hdev->shutdown(hdev);
  	}

  	btusb_stop_traffic(data);
  	usb_kill_anchored_urbs(&data->tx_anchor);

  	if (!err)
  		usb_autopm_put_interface(data->intf);
  }
  ```

#### 2. `drivers/net/wireless/realtek/rtw88/pci.c`
* **Find `void rtw_pci_shutdown(struct pci_dev *pdev)`** (near the bottom of the file, around line 1910) and replace its body with:
  ```c
  void rtw_pci_shutdown(struct pci_dev *pdev)
  {
  	struct ieee80211_hw *hw = pci_get_drvdata(pdev);
  	struct rtw_dev *rtwdev;
  	struct rtw_pci *rtwpci;
  	const struct rtw_chip_info *chip;

  	if (!hw)
  		return;

  	rtwdev = hw->priv;
  	rtwpci = (struct rtw_pci *)rtwdev->priv;
  	chip = rtwdev->chip;

  	mutex_lock(&rtwdev->mutex);
  	if (test_bit(RTW_FLAG_POWERON, rtwdev->flags)) {
  		clear_bit(RTW_FLAG_RUNNING, rtwdev->flags);
  		clear_bit(RTW_FLAG_FW_RUNNING, rtwdev->flags);
  		rtw_power_off(rtwdev);
  		clear_bit(RTW_FLAG_POWERON, rtwdev->flags);
  	}
  	else
  		rtw_hci_link_ps(rtwdev, false);
  	mutex_unlock(&rtwdev->mutex);

  	rtw_pci_disable_interrupt(rtwdev, rtwpci);

  	if (chip->ops->shutdown)
  		chip->ops->shutdown(rtwdev);

  	pci_set_power_state(pdev, PCI_D3hot);
  }
  ```

---

## Step 4: Compile, Install & Power-Cycle

```bash
make -C /usr/lib/modules/$(uname -r)/build M=$(pwd)/drivers/bluetooth modules
make -C /usr/lib/modules/$(uname -r)/build M=$(pwd)/drivers/net/wireless/realtek/rtw88 modules

sudo mkdir -p /usr/lib/modules/$(uname -r)/updates
sudo cp drivers/bluetooth/{btusb,btrtl,btmtk,btintel,btbcm}.ko /usr/lib/modules/$(uname -r)/updates/
sudo cp drivers/net/wireless/realtek/rtw88/rtw88_pci.ko /usr/lib/modules/$(uname -r)/updates/
sudo depmod -a
```

Perform **one full shutdown (power off completely)** and power back on so the patched modules load cleanly.

---

## Rollback to Stock Modules

```bash
for mod in btusb btrtl btmtk btintel btbcm rtw88_pci; do
    sudo rm -f "/usr/lib/modules/$(uname -r)/updates/${mod}.ko"
done
sudo depmod -a
```
