# Realtek RTL8723DE (`10ec:d723` / `0bda:b009`) Warm-Reboot Hang & Coexistence Analysis

- **Interactive Web Guide:** https://sudo-WearTherinG.github.io/linux-rtl8723de-driver-patch/
- **Manual Future-Kernel Guide:** `apply_yourself_guide.md`

## 1. Hardware & System Overview

The **Realtek RTL8723DE** M.2 combo adapter integrates two distinct host bus interfaces onto a single silicon die sharing an internal power-management unit, coexistence scheduler, and a single (`1x1`) 2.4 GHz antenna:

| Function | Bus Interface | PCI / USB ID | Linux Kernel Driver |
| :--- | :--- | :--- | :--- |
| **Wi-Fi (802.11b/g/n)** | PCIe | `10ec:d723` | `rtw88_8723de` (`rtw88_pci`) |
| **Bluetooth (4.2)** | USB | `0bda:b009` | `btusb` + `btrtl` |

- **Tested Platform:** HP Laptop (`15-da0xxx`), Arch-based Omarchy Linux (`7.2.15-4-omarchy`)
- **Firmware Versions:** Wi-Fi `48.0.0` (`H2C version 0`), Bluetooth `rtl8723d_fw.bin` (`0x828a96f1`)

---

## 2. The Two Distinct Issues on RTL8723DE

### Issue A: Complete Loss of Wi-Fi and Bluetooth After Warm Reboot (Kernel Driver Bug)

When performing a warm reboot (`reboot` / `systemctl reboot`) from a cold boot with internal Bluetooth active, **both** the USB Bluetooth controller and PCIe Wi-Fi adapter fail to initialize on the next boot.

#### Kernel Log Evidence (`dmesg` / `journalctl -k`)

1. **USB Bluetooth fails enumeration first (`-71` / `EPROTO`):**

   ```text
   usb 1-6: new full-speed USB device number 3 using xhci_hcd
   usb 1-6: device descriptor read/64, error -71
   usb 1-6: Device not responding to setup address.
   usb 1-6: device not accepting address 5, error -71
   ```

2. **PCIe Wi-Fi fails MAC power-on immediately afterward (-16 / -EBUSY):**

   ```text
   rtw88_8723de 0000:02:00.0: Firmware version 48.0.0, H2C version 0
   rtw88_8723de 0000:02:00.0: failed to poll offset=0x5 mask=0x1 value=0x0
   rtw88_8723de 0000:02:00.0: mac power on failed
   rtw88_8723de 0000:02:00.0: failed to power on mac
   rtw88_8723de 0000:02:00.0: failed to setup chip efuse info
   rtw88_8723de 0000:02:00.0: probe with driver rtw88_8723de failed with error -16
   ```

   - offset=0x5 (mask=0x1) corresponds to BIT_APFM_ONMAC in REG_APS_FSMCO + 1 (the shared Auto Power-On MAC state machine). Because the shared silicon power domain was not cleanly reset prior to the warm reset, polling for 0x0 times out and returns -EBUSY (-16).

### Issue B: 2.4 GHz Single-Antenna Coexistence Throughput Collapse (Firmware/Hardware Limit)

When streaming A2DP Bluetooth audio over internal Bluetooth (0bda:b009) while connected to 2.4 GHz Wi-Fi (rtw88_8723de):

- Wi-Fi RX bitrates collapse to 1–2 MBit/s (CCK_1M) and dmesg logs:

  ```text
  rtw88_8723de 0000:02:00.0: failed to get tx report from firmware
  ```

- Root cause: The RTL8723DE is a 1x1 single-antenna chip. Time-division multiplexing (TDMA) arbitration between Bluetooth SCO/A2DP slots and 2.4 GHz Wi-Fi frames is executed inside Realtek's closed-source firmware (rtw8723d_fw.bin), starving Wi-Fi RX/TX windows during continuous audio streaming.
- Workaround: Disabling internal Realtek Bluetooth (0bda:b009) and offloading Bluetooth audio to an external USB Bluetooth adapter eliminates single-antenna 2.4 GHz airtime contention completely.

---

## 3. Empirical Reboot State Matrix (Unpatched Kernel 7.2.15)

Controlled testing across cold boots and consecutive warm reboots established the exact trigger condition:

| Initial State Before Reboot | Warm Reboot #1 | Warm Reboot #2 (from broken state) |
| :--- | :--- | :--- |
| Cold boot → BT ON, Wi-Fi ON | FAIL (both vanish) | PASS (both recover) |
| Cold boot → BT ON, Wi-Fi OFF | FAIL (both vanish) | PASS (both recover) |
| Cold boot → BT OFF, Wi-Fi ON | PASS | PASS |
| Cold boot → BT OFF, Wi-Fi OFF | PASS | PASS |

### Key Takeaways from the Matrix

1. Bluetooth's pre-reboot state is the decisive trigger: Whether Wi-Fi is ON or OFF before reboot does not prevent the failure if internal Bluetooth was active.
2. A second warm reboot from a broken state always recovers: Because neither btusb nor rtw88_8723de successfully probed or loaded firmware during the failed boot, the chip sits unconfigured during the subsequent warm reboot and resets cleanly.

---

## 4. Kernel Source Root-Cause Analysis

### 1. Missing .shutdown Handler in drivers/bluetooth/btusb.c

- In drivers/bluetooth/btrtl.c, Realtek defines btrtl_shutdown_realtek(struct hci_dev *hdev), which sends HCI_OP_RESET with the explicit vendor comment:

  ```c
  /* According to the vendor driver, BT must be reset on close to avoid
   * firmware crash.
   */
  ```

- However, btusb_driver (drivers/bluetooth/btusb.c) registers .disconnect = btusb_disconnect, but omits .shutdown.
- During kernel_restart() → device_shutdown(), .disconnect is not called. When userspace (systemd) stops bluetooth.service moments before kernel device shutdown, btusb_close() leaves needs_remote_wakeup = 1 armed on the USB interface (BTUSB_WAKEUP_AUTOSUSPEND) while Realtek firmware remains resident in chip RAM.

### 2. Incomplete Shutdown Sequence in drivers/net/wireless/realtek/rtw88/pci.c

- rtw_pci_shutdown() invokes chip->ops->shutdown(rtwdev) (rtw8723d_shutdown(), which only sets BIT_USB_SUS_DIS in REG_HCI_OPT_CTRL) and immediately calls pci_set_power_state(pdev, PCI_D3hot) without calling rtw_power_off(rtwdev) or disabling PCI interrupts when RTW_FLAG_POWERON is still active.

### 3. Critical Deadlocks & Edge Cases Discovered During Testing

1. **Never call btusb_disconnect() or usb_reset_device() inside usb_driver.shutdown():**
   - device_shutdown() already holds device_lock(&udev->dev). Calling hci_unregister_dev() (via btusb_disconnect) or usb_reset_device() inside .shutdown() deadlocks on the USB device mutex and triggers a kernel panic during reboot.

2. **Never wake an autosuspended Bluetooth controller if it was never opened during that boot:**
   - Calling usb_autopm_get_interface() unconditionally in btusb_shutdown() when Bluetooth was already toggled OFF in userspace wakes the suspended controller (RPM_ACTIVE), while __hci_cmd_sync() aborts with -ENETDOWN (!HCI_UP)—causing consecutive reboots with Bluetooth OFF to wedge on Reboot #2.
   - Tracking BTUSB_NEEDS_SHUTDOWN_RESET in btusb_open() ensures btusb_shutdown() wakes and resets the controller only when Bluetooth was actually opened during that session, while always clearing needs_remote_wakeup = 0 and stopping active URBs.

---

## 5. Final Verified Kernel Patch (v7.2.15)

```diff
diff --git a/drivers/bluetooth/btusb.c b/drivers/bluetooth/btusb.c
index bf9a93d..8dd07fe 100644
--- a/drivers/bluetooth/btusb.c
+++ b/drivers/bluetooth/btusb.c
@@ -990,6 +990,7 @@ struct qca_dump_info {
 #define BTUSB_HW_SSR_ACTIVE	17
 #define BTUSB_WAKEUP_BROKEN	18
 #define BTUSB_RESET		19
+#define BTUSB_NEEDS_SHUTDOWN_RESET	20
 
 struct btusb_data {
 	struct hci_dev       *hdev;
@@ -2047,6 +2048,7 @@ static int btusb_open(struct hci_dev *hdev)
 	}
 
 	data->intf->needs_remote_wakeup = 1;
+	set_bit(BTUSB_NEEDS_SHUTDOWN_RESET, &data->flags);
 
 	if (test_and_set_bit(BTUSB_INTR_RUNNING, &data->flags))
 		goto done;
@@ -4805,10 +4807,37 @@ static void btusb_coredump(struct device *dev)
 }
 #endif
 
+static void btusb_shutdown(struct usb_interface *intf)
+{
+	struct btusb_data *data = usb_get_intfdata(intf);
+	struct hci_dev *hdev;
+	int err = -1;
+
+	if (!data || intf != data->intf)
+		return;
+
+	hdev = data->hdev;
+	data->intf->needs_remote_wakeup = 0;
+	data->udev->do_remote_wakeup = 0;
+
+	if (test_and_clear_bit(BTUSB_NEEDS_SHUTDOWN_RESET, &data->flags) &&
+	    hdev->shutdown) {
+		err = usb_autopm_get_interface(data->intf);
+		hdev->shutdown(hdev);
+	}
+
+	btusb_stop_traffic(data);
+	usb_kill_anchored_urbs(&data->tx_anchor);
+
+	if (!err)
+		usb_autopm_put_interface(data->intf);
+}
+
 static struct usb_driver btusb_driver = {
 	.name		= "btusb",
 	.probe		= btusb_probe,
 	.disconnect	= btusb_disconnect,
+	.shutdown	= btusb_shutdown,
 	.suspend	= pm_ptr(btusb_suspend),
 	.resume		= pm_ptr(btusb_resume),
 	.id_table	= btusb_table,
diff --git a/drivers/net/wireless/realtek/rtw88/pci.c b/drivers/net/wireless/realtek/rtw88/pci.c
index 69f2840..77e3524 100644
--- a/drivers/net/wireless/realtek/rtw88/pci.c
+++ b/drivers/net/wireless/realtek/rtw88/pci.c
@@ -1910,14 +1910,29 @@ void rtw_pci_shutdown(struct pci_dev *pdev)
 {
 	struct ieee80211_hw *hw = pci_get_drvdata(pdev);
 	struct rtw_dev *rtwdev;
+	struct rtw_pci *rtwpci;
 	const struct rtw_chip_info *chip;
 
 	if (!hw)
 		return;
 
 	rtwdev = hw->priv;
+	rtwpci = (struct rtw_pci *)rtwdev->priv;
 	chip = rtwdev->chip;
 
+	mutex_lock(&rtwdev->mutex);
+	if (test_bit(RTW_FLAG_POWERON, rtwdev->flags)) {
+		clear_bit(RTW_FLAG_RUNNING, rtwdev->flags);
+		clear_bit(RTW_FLAG_FW_RUNNING, rtwdev->flags);
+		rtw_power_off(rtwdev);
+		clear_bit(RTW_FLAG_POWERON, rtwdev->flags);
+	}
+	else
+		rtw_hci_link_ps(rtwdev, false);
+	mutex_unlock(&rtwdev->mutex);
+
+	rtw_pci_disable_interrupt(rtwdev, rtwpci);
+
 	if (chip->ops->shutdown)
 		chip->ops->shutdown(rtwdev);
```

### Post-Patch Verification Matrix

- Cold boot → Wi-Fi ON + BT ON → Consecutive Warm Reboots: PASS
- Cold boot → Wi-Fi OFF + BT ON → Consecutive Warm Reboots: PASS
- Cold boot → Wi-Fi ON + BT OFF → Consecutive Warm Reboots (Run 1 & Run 2): PASS
- Cold boot → Wi-Fi OFF + BT OFF → Consecutive Warm Reboots: PASS

---

## 6. Installation & Rollback

### Prerequisites

See REQUIREMENTS.txt to install matching kernel headers and build tools (base-devel and linux-headers / linux-omarchy-headers).

### Install

```bash
chmod +x install.sh
unzip src.zip
./install.sh
```

After installation completes, perform one full shutdown (power off completely) and power back on so the patched modules load cleanly.

### Verify Active Override

```bash
modinfo btusb rtw88_pci | grep -E "filename|srcversion"
```

Both modules should resolve to /lib/modules/$(uname -r)/updates/.

### Rollback to Stock Kernel Modules

```bash
./install.sh --uninstall
```

> **Update (`0x0bda:0xb009` Autosuspend Quirk):** Also disables USB runtime autosuspend (`enable_autosuspend = false`) for `0x0bda:0xb009` in `btusb.c` so toggling Bluetooth off mid-session does not wedge the shared power rail across warm reboots.
