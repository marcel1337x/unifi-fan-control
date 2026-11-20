#!/bin/bash
set -e

HWMON_BASE="${FAN_CONTROL_HWMON_BASE:-/sys/class/hwmon}"
SERVICE_FILE="${FAN_CONTROL_SERVICE_FILE:-/etc/systemd/system/fan-control.service}"
# install.sh points the unit at the install dir, which may be a git checkout.
INSTALL_DIR="${FAN_CONTROL_INSTALL_DIR:-$(sed -n 's/^WorkingDirectory=//p' "$SERVICE_FILE" 2>/dev/null || true)}"
INSTALL_DIR="${INSTALL_DIR#-}" # systemd's "ignore if missing" prefix
INSTALL_DIR="${INSTALL_DIR:-/data/fan-control}"
DATA_ROOT="${FAN_CONTROL_DATA_ROOT:-/data}"
PID_FILE="${FAN_CONTROL_PID_FILE:-/var/run/fan-control.pid}"

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Check for systemd availability
if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Stop and disable service
systemctl stop fan-control.service 2>/dev/null || true
systemctl disable fan-control.service 2>/dev/null || true

# Leave every fan channel under control. Stopping the service has already run the
# daemon's EXIT trap, which hands an lm63 to its own fan curve (automatic mode).
# Channels still in manual mode get a fixed safe speed: PWM 0 would leave the fan
# stopped with nothing driving it, since UniFi OS does not take the channel back.
# Mirrors the detection logic in fan-control.sh to find all active channels
FALLBACK_PWM=180
reset_ok=false

leave_pwm() {
    mode=$(cat "${1}_enable" 2>/dev/null) || mode=""
    if [ -n "$mode" ] && [ "$mode" != 1 ]; then
        echo "Leaving $1 under hardware control (mode $mode)"
        reset_ok=true
    else
        echo "Setting $1 to $FALLBACK_PWM..."
        echo "$FALLBACK_PWM" >"$1" 2>/dev/null && reset_ok=true
    fi
}

# Strategy 1: pwm files directly in hwmon class directories
for pwm_file in "$HWMON_BASE"/hwmon*/pwm[1-9]; do
    if [ -e "$pwm_file" ]; then
        leave_pwm "$pwm_file"
    fi
done

# Strategy 2: raw device paths (for UDM-SE where class dir has no pwm files)
if [ "$reset_ok" = false ]; then
    for hwmon_dir in "$HWMON_BASE"/hwmon*; do
        dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null) || continue
        for pwm_file in "$dev_path"/pwm[1-9]; do
            if [ -e "$pwm_file" ]; then
                leave_pwm "$pwm_file"
            fi
        done
    done
fi

[ "$reset_ok" = false ] && echo "Warning: No PWM devices found to reset"

# Remove system files
echo "Removing system files..."
rm -f "$SERVICE_FILE" || echo "Warning: Could not remove service file"
rm -f "$PID_FILE" || echo "Warning: Could not remove PID file"

# Remove data files
echo "Removing data files..."
# INSTALL_DIR comes from the unit file, so only ever rm -rf something that is
# demonstrably a fan-control install, and never / or the persistent data root.
resolved_dir=$(readlink -f "$INSTALL_DIR" 2>/dev/null || true)
if [ -d "$INSTALL_DIR" ] && {
    [ -z "$resolved_dir" ] || [ "$resolved_dir" = / ] ||
        [ "$resolved_dir" = "$(readlink -f "$DATA_ROOT" 2>/dev/null || echo "$DATA_ROOT")" ] ||
        [ ! -f "$INSTALL_DIR/fan-control.sh" ]
}; then
    echo "Warning: $INSTALL_DIR does not look like a fan-control install; not removing it"
elif [ -e "$INSTALL_DIR/.git" ]; then
    # The install dir is a git checkout running in place: keep it, drop only runtime state.
    rm -f "$INSTALL_DIR"/config "$INSTALL_DIR"/temp_state "$INSTALL_DIR"/optimal_pwm "$INSTALL_DIR"/*.tmp || {
        echo "Warning: Could not remove runtime state from $INSTALL_DIR"
    }
    echo "Kept git checkout at $INSTALL_DIR"
elif [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR" || {
        echo "Warning: Could not remove data directory"
        echo "You may need to manually remove $INSTALL_DIR"
    }
else
    echo "Data directory not found, skipping"
fi

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. All components removed."
