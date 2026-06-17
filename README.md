# device-notify

Desktop notifications for USB connect/disconnect, storage drives, and Bluetooth devices on Linux.

Uses udev rules to fire instantly on device events — no polling, no background service.

## What it shows

- **USB devices** — mouse, keyboard, gamepad, dongle, headset, etc.
- **Storage drives** — USB drives and external disks
- **Bluetooth devices** — keyboard, mouse, headset, etc.

## Dependencies

| Distro | Install command |
|--------|----------------|
| Arch / CachyOS | `sudo pacman -S libnotify bluez-utils util-linux` |
| Fedora | `sudo dnf install libnotify bluez util-linux` |
| Debian / Ubuntu | `sudo apt install libnotify-bin bluez util-linux` |

- `libnotify` — provides `notify-send`
- `util-linux` — provides `runuser`
- `bluez-utils` (Arch) / `bluez` (Fedora/Debian) — provides `bluetoothctl` for Bluetooth device names
- An icon theme with standard freedesktop icons (Adwaita, Papirus, Breeze all work)

## Install

```bash
# 1. Copy the script
sudo cp device-notify.sh /usr/local/bin/device-notify.sh
sudo chmod +x /usr/local/bin/device-notify.sh

# 2. Copy the udev rule
sudo cp 99-notification.rules /etc/udev/rules.d/99-notification.rules

# 3. Reload udev rules
sudo udevadm control --reload-rules
```

That's it. Unplug a USB device to test.

## Uninstall

```bash
sudo rm /usr/local/bin/device-notify.sh
sudo rm /etc/udev/rules.d/99-notification.rules
sudo udevadm control --reload-rules
rm -rf /run/usb-notify/
rm -rf ~/.config/device-notify/
```

## Configuration

Everything works zero-config. To customize, create a config file:

```bash
mkdir -p ~/.config/device-notify
cp config.example ~/.config/device-notify/config
# Edit to your liking
nano ~/.config/device-notify/config
```

### Global settings

| Key | Default | Description |
|-----|---------|-------------|
| `APP_NAME` | `Device Manager` | App name shown in notification header |
| `TIMEOUT` | `5000` | Notification timeout in ms (0 = persistent) |
| `URGENCY` | `normal` | Notification urgency: `low`, `normal`, `critical` |
| `NOTIFY_ICON` | (empty) | Override all icons with a single icon name |

### Custom titles

| Key | Default |
|-----|---------|
| `TITLE_USB_CONNECT` | `USB Connected` |
| `TITLE_USB_DISCONNECT` | `USB Disconnected` |
| `TITLE_BT_CONNECT` | `Bluetooth Connected` |
| `TITLE_BT_DISCONNECT` | `Bluetooth Disconnected` |
| `TITLE_DRIVE_CONNECT` | `Drive Connected` |
| `TITLE_DRIVE_DISCONNECT` | `Drive Disconnected` |
| `TITLE_DEFAULT_CONNECT` | `Device Connected` |
| `TITLE_DEFAULT_DISCONNECT` | `Device Disconnected` |

### Device icon overrides

Override the icon for specific devices:

```ini
# Exact name match
ICON_ATK ZERO=input-mouse

# Wildcard matching (case-insensitive, first match wins)
ICON_*Gamepad*=input-gaming
ICON_*Mouse*=input-mouse
ICON_*Keyboard*=input-keyboard
ICON_*Headset*=audio-headset
ICON_*Speaker*=audio-speakers
```

### Icon detection priority

1. User overrides from config (`ICON_ATK ZERO=input-mouse`)
2. Sysfs `icon_name` file (HID devices)
3. `ID_USB_INTERFACES` HID class codes (auto-detects mouse/keyboard/gamepad)
4. Name pattern matching (last resort)

Common icon names: `input-mouse`, `input-keyboard`, `input-gaming`, `input-tablet`, `audio-headset`, `audio-speakers`, `drive-harddisk-usb`, `bluetooth`, `camera-web`, `printer`

## How it works

1. **udev rules** detect device add/remove events and run the script as root
2. The script escapes the udev sandbox using `runuser` to reach the user's D-Bus session
3. **USB/Storage**: Device names are cached in `/run/usb-notify/` on connect, read on disconnect (udev doesn't provide device info on remove)
4. **Bluetooth**: On connect/disconnect, diffs the current connected device list against a cached list. Queries `bluetoothctl` for device names and icons
5. `notify-send` delivers the notification to whatever notification daemon is running

## Notes

- Requires a notification daemon running (D-Bus `org.freedesktop.Notifications`)
- Icons depend on your icon theme having standard freedesktop icon names
- Bluetooth notifications are slightly slower (~2-3s) because `bluetoothctl` queries are slow
- Cache is stored in `/run/usb-notify/` (tmpfs, cleared on reboot)

## License

MIT
