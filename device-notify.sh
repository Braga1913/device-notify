#!/bin/bash

# device-notify — Desktop notifications for USB/Bluetooth/Storage device events
# Called by udev rules, runs as root, notifies user's desktop session
#
# Dependencies: bash, libnotify (notify-send), util-linux (runuser)
# Optional:     bluez-utils (bluetoothctl) for Bluetooth device names
#
# Config: ~/.config/device-notify/config (see config.example)
# Config is optional — everything works zero-config with auto-detection.

# --- Configuration ---
CACHE_DIR="/run/usb-notify"
BT_CACHE="$CACHE_DIR/bt-devices"
CONFIG_DIR="$HOME/.config/device-notify"
CONFIG_FILE="$CONFIG_DIR/config"

# Auto-detect user from D-Bus session bus
detect_user() {
    local uid_path
    uid_path=$(ls -1 /run/user/*/bus 2>/dev/null | head -1)
    if [ -n "$uid_path" ]; then
        local uid="${uid_path#/run/user/}"
        uid="${uid%/bus}"
        local user
        user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
        if [ -n "$user" ] && [ "$user" != "root" ]; then
            echo "$uid $user"
            return
        fi
    fi
    local user
    user=$(who 2>/dev/null | awk 'NF>1 && $1!="root" {print $1; exit}')
    if [ -n "$user" ]; then
        local uid
        uid=$(id -u "$user" 2>/dev/null)
        echo "$uid $user"
        return
    fi
    echo "1000 $(id -un 1000 2>/dev/null || echo braga)"
}

if [ -z "$NOTIFY_USER" ] || [ -z "$NOTIFY_UID" ]; then
    read -r DETECTED_UID DETECTED_USER <<< "$(detect_user)"
    TARGET_USER="${NOTIFY_USER:-$DETECTED_USER}"
    TARGET_UID="${NOTIFY_UID:-$DETECTED_UID}"
else
    TARGET_USER="$NOTIFY_USER"
    TARGET_UID="$NOTIFY_UID"
fi

mkdir -p "$CACHE_DIR"

# --- Config Reader ---
# Read config from the target user's home directory
CONFIG_CONTENT=""
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_CONTENT=$(cat "$CONFIG_FILE" 2>/dev/null)
elif [ -d "/home/$TARGET_USER" ]; then
    USER_CONFIG="/home/$TARGET_USER/.config/device-notify/config"
    if [ -f "$USER_CONFIG" ]; then
        CONFIG_CONTENT=$(cat "$USER_CONFIG" 2>/dev/null)
    fi
fi

get_config() {
    local key="$1"
    local default="${2:-}"
    local value
    value=$(echo "$CONFIG_CONTENT" | grep -E "^${key}=" | tail -1 | cut -d= -f2-)
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Load global config with defaults
APP_NAME=$(get_config "APP_NAME" "Device Manager")
NOTIFY_TIMEOUT=$(get_config "TIMEOUT" "5000")
NOTIFY_URGENCY=$(get_config "URGENCY" "normal")
NOTIFY_ICON_OVERRIDE="${NOTIFY_ICON:-$(get_config "NOTIFY_ICON" "")}"

# Load title overrides
TITLE_USB_CONNECT=$(get_config "TITLE_USB_CONNECT" "USB Connected")
TITLE_USB_DISCONNECT=$(get_config "TITLE_USB_DISCONNECT" "USB Disconnected")
TITLE_BT_CONNECT=$(get_config "TITLE_BT_CONNECT" "Bluetooth Connected")
TITLE_BT_DISCONNECT=$(get_config "TITLE_BT_DISCONNECT" "Bluetooth Disconnected")
TITLE_DRIVE_CONNECT=$(get_config "TITLE_DRIVE_CONNECT" "Drive Connected")
TITLE_DRIVE_DISCONNECT=$(get_config "TITLE_DRIVE_DISCONNECT" "Drive Disconnected")
TITLE_DEFAULT_CONNECT=$(get_config "TITLE_DEFAULT_CONNECT" "Device Connected")
TITLE_DEFAULT_DISCONNECT=$(get_config "TITLE_DEFAULT_DISCONNECT" "Device Disconnected")

# --- Icon Overrides ---
# Match device name against ICON_{pattern} config entries
# Supports * wildcards, first match wins
get_override_icon() {
    local devname="$1"
    [ -z "$devname" ] && return
    echo "$CONFIG_CONTENT" | grep -E "^ICON_[^=]+=+" | while IFS='=' read -r key value; do
        local pattern="${key#ICON_}"
        # Convert glob pattern to regex: * -> .*
        local regex
        regex=$(printf '%s' "$pattern" | sed 's/[.[\*^$()+?{|]/\\&/g; s/\\\*/.*/g')
        if echo "$devname" | grep -qiE "^${regex}$"; then
            echo "$value"
            return
        fi
    done
}

# --- Helpers ---
decode() {
    printf '%b' "${1//%/\\x}"
}

# Detect icon from USB HID interface class codes
# ID_USB_INTERFACES format: :XXYYZZ:XXYYZZ:
#   XX = class, YY = subclass, ZZ = protocol
#   03/01/01 = HID Boot Mouse
#   03/01/02 = HID Boot Keyboard
#   03/01/03 = HID Boot Gamepad
get_icon_from_interfaces() {
    local ifaces="$1"
    # Check for mouse first, then keyboard, then gamepad
    case "$ifaces" in
        *030101*) echo "input-mouse"; return ;;
        *030102*) echo "input-keyboard"; return ;;
        *030103*) echo "input-gaming"; return ;;
    esac
    return 1
}

get_usb_icon() {
    local name="$1"
    local devpath="$2"

    # 1. User overrides from config
    local override
    override=$(get_override_icon "$name")
    if [ -n "$override" ]; then
        echo "$override"
        return
    fi

    # 2. Sysfs icon_name file
    if [ -n "$devpath" ]; then
        for icon_file in /sys"$devpath"/icon_name /sys"$devpath"/../icon_name; do
            if [ -f "$icon_file" ]; then
                local sysicon
                sysicon=$(cat "$icon_file" 2>/dev/null)
                [ -n "$sysicon" ] && echo "$sysicon" && return
            fi
        done
    fi

    # 3. USB HID interface class codes
    if [ -n "$ID_USB_INTERFACES" ]; then
        local hid_icon
        hid_icon=$(get_icon_from_interfaces "$ID_USB_INTERFACES")
        [ -n "$hid_icon" ] && echo "$hid_icon" && return
    fi

    # 4. Name-based fallback
    case "$name" in
        *[Mm]ouse*)              echo "input-mouse" ;;
        *[Kk]eyboard*)           echo "input-keyboard" ;;
        *[Gg]amepad*|[Gg]ame*)   echo "input-gaming" ;;
        *[Tt]ablet*)             echo "input-tablet" ;;
        *[Dd]ongle*)             echo "input-mouse" ;;
        *[Hh]eadset*)            echo "audio-headset" ;;
        *[Ss]peaker*)            echo "audio-speakers" ;;
        *[Ss]torage*|[Dd]rive*)  echo "drive-harddisk-usb" ;;
        *)                       echo "drive-harddisk-usb" ;;
    esac
}

send_notification() {
    local icon="$1"
    local title="$2"
    local body="$3"

    # Apply global icon override
    [ -n "$NOTIFY_ICON_OVERRIDE" ] && icon="$NOTIFY_ICON_OVERRIDE"

    exec runuser -u "$TARGET_USER" -- \
        env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
        XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
        /usr/bin/notify-send \
            -a "$APP_NAME" \
            -i "$icon" \
            -u "$NOTIFY_URGENCY" \
            -t "$NOTIFY_TIMEOUT" \
            "$title" "$body"
}

# --- Main ---

CACHE_KEY=$(echo "$DEVPATH" | sed 's|/|_|g; s|^_||')
name=""
ICON=""
TITLE=""

case "$SUBSYSTEM" in
    usb)
        if [ "$ACTION" = "add" ]; then
            if [ -n "$ID_MODEL_ENC" ]; then
                name=$(decode "$ID_MODEL_ENC")
            elif [ -n "$ID_MODEL" ]; then
                name="$ID_MODEL"
            fi
            ICON="$(get_usb_icon "$name" "$DEVPATH")"
            [ -n "$name" ] && echo "${name}|||${ICON}" > "$CACHE_DIR/$CACHE_KEY"
        elif [ "$ACTION" = "remove" ]; then
            if [ -f "$CACHE_DIR/$CACHE_KEY" ]; then
                cached=$(cat "$CACHE_DIR/$CACHE_KEY")
                name="${cached%%|||*}"
                ICON="${cached##*|||}"
                rm -f "$CACHE_DIR/$CACHE_KEY"
            fi
        fi
        if [ "$ACTION" = "add" ]; then
            TITLE="$TITLE_USB_CONNECT"
        else
            TITLE="$TITLE_USB_DISCONNECT"
        fi
        ;;
    bluetooth)
        CURRENT=$(mktemp)
        runuser -u "$TARGET_USER" -- bluetoothctl devices 2>/dev/null | while read -r _ addr rest; do
            if runuser -u "$TARGET_USER" -- bluetoothctl info "$addr" 2>/dev/null | grep -q "Connected: yes"; then
                bticon=$(runuser -u "$TARGET_USER" -- bluetoothctl info "$addr" 2>/dev/null | grep "Icon:" | sed 's/.*Icon: //')
                echo "${rest}|||${bticon:-bluetooth}"
            fi
        done | sort > "$CURRENT"

        if [ "$ACTION" = "add" ] && [ -s "$CURRENT" ]; then
            if [ -f "$BT_CACHE" ]; then
                diff_line=$(comm -13 "$BT_CACHE" "$CURRENT" | head -1)
            else
                diff_line=$(head -1 "$CURRENT")
            fi
            mv "$CURRENT" "$BT_CACHE"
            name="${diff_line%%|||*}"
            ICON="${diff_line##*|||}"
            # Check overrides for bluetooth too
            local override
            override=$(get_override_icon "$name")
            [ -n "$override" ] && ICON="$override"
            TITLE="$TITLE_BT_CONNECT"
        elif [ "$ACTION" = "remove" ]; then
            if [ -f "$BT_CACHE" ]; then
                diff_line=$(comm -23 "$BT_CACHE" "$CURRENT" | head -1)
                mv "$CURRENT" "$BT_CACHE"
                name="${diff_line%%|||*}"
                ICON="${diff_line##*|||}"
                local override
                override=$(get_override_icon "$name")
                [ -n "$override" ] && ICON="$override"
            else
                rm -f "$CURRENT"
                name="Bluetooth Device"
                ICON="bluetooth"
            fi
            TITLE="$TITLE_BT_DISCONNECT"
        else
            rm -f "$CURRENT"
            name="Bluetooth Device"
            ICON="bluetooth"
            TITLE="$TITLE_DEFAULT_CONNECT"
        fi
        ;;
    block)
        if [ "$ACTION" = "add" ]; then
            if [ -n "$ID_FS_LABEL" ]; then
                name="$ID_FS_LABEL"
            elif [ -n "$ID_MODEL" ]; then
                name=$(decode "$ID_MODEL")
            fi
            ICON="drive-harddisk-usb"
            [ -n "$name" ] && echo "${name}|||${ICON}" > "$CACHE_DIR/$CACHE_KEY"
        elif [ "$ACTION" = "remove" ]; then
            if [ -f "$CACHE_DIR/$CACHE_KEY" ]; then
                cached=$(cat "$CACHE_DIR/$CACHE_KEY")
                name="${cached%%|||*}"
                ICON="${cached##*|||}"
                rm -f "$CACHE_DIR/$CACHE_KEY"
            fi
        fi
        if [ "$ACTION" = "add" ]; then
            TITLE="$TITLE_DRIVE_CONNECT"
        else
            TITLE="$TITLE_DRIVE_DISCONNECT"
        fi
        ;;
    *)
        name="Device"
        ICON="drive-harddisk-usb"
        if [ "$ACTION" = "add" ]; then
            TITLE="$TITLE_DEFAULT_CONNECT"
        else
            TITLE="$TITLE_DEFAULT_DISCONNECT"
        fi
        ;;
esac

DEVICE_NAME="${name:-Unknown Device}"
[ -z "$ICON" ] && ICON="drive-harddisk-usb"

send_notification "$ICON" "$TITLE" "$DEVICE_NAME"
