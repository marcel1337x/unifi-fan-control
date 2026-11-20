#!/bin/bash
###############################################################################
# Exit hand-off: an lm63 in manual mode is given the config curve and automatic
# mode, and the next start takes it back. (Fallback PWM is covered by the
# lifecycle test, whose fake driver has no pwm1_enable.)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

make_lm63() {
    local hwmon="$SANDBOX/hwmon/hwmon0"
    local point
    echo lm63 >"$hwmon/name"
    echo "$1" >"$hwmon/pwm1_enable"
    # UniFi OS ships every lookup-table point as 127 °C / 255.
    for point in 1 2 3 4 5 6 7 8; do
        echo 127000 >"$hwmon/pwm1_auto_point${point}_temp"
        echo 255 >"$hwmon/pwm1_auto_point${point}_pwm"
    done
}

hwmon_value() {
    cat "$SANDBOX/hwmon/hwmon0/$1"
}

declare -i scenario=0

# ── Scenario 1: manual lm63 is handed to automatic mode with the config curve ─
scenario=$((scenario + 1))
setup_sandbox
make_lm63 1

echo "70" >"$SANDBOX/cputemp"
start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0
stop_daemon

assert_eq "$(hwmon_value pwm1_enable)" "2" "pwm1_enable after exit: "
# Defaults: MIN_TEMP 60 → MAX_TEMP 85, MIN_PWM 91 → MAX_PWM 255 over 8 points.
assert_eq "$(hwmon_value pwm1_auto_point1_temp)" "60000" "first point temp: "
assert_eq "$(hwmon_value pwm1_auto_point1_pwm)" "91" "first point pwm: "
assert_eq "$(hwmon_value pwm1_auto_point4_temp)" "70000" "middle point temp: "
assert_eq "$(hwmon_value pwm1_auto_point8_temp)" "85000" "last point temp: "
assert_eq "$(hwmon_value pwm1_auto_point8_pwm)" "255" "last point pwm: "
assert_contains "$(cat "$SANDBOX/syslog")" "EXIT: .*pwm1 handed to lm63 automatic mode (60-85°C → 91-255pwm)"
echo "  ✓ Scenario ${scenario}: manual lm63 handed to automatic mode with the config curve"

# ── Scenario 2: the next start takes the channel back into manual mode ────────
scenario=$((scenario + 1))
: >"$SANDBOX/syslog"
echo 0 >"$SANDBOX/hwmon/hwmon0/pwm1"
start_daemon
wait_for_log "INIT: Took .*pwm1 back from lm63 automatic mode" 5
assert_eq "$(hwmon_value pwm1_enable)" "1" "pwm1_enable after restart: "
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0
echo "  ✓ Scenario ${scenario}: restart takes the lm63 back and controls it"

stop_daemon
cleanup_sandbox

# ── Scenario 3: a channel already under hardware control is left alone ───────
scenario=$((scenario + 1))
setup_sandbox
echo 2 >"$SANDBOX/hwmon/hwmon0/pwm1_enable"

echo "70" >"$SANDBOX/cputemp"
start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0
pwm_before=$(get_pwm)
stop_daemon

assert_eq "$(hwmon_value pwm1_enable)" "2" "hardware mode after exit: "
assert_eq "$(get_pwm)" "$pwm_before" "PWM of hardware-controlled channel: "
if grep -q 'EXIT:' "$SANDBOX/syslog"; then
    fail "hardware-controlled channel was handed off or set to the fallback"
fi
echo "  ✓ Scenario ${scenario}: non-lm63 channel in automatic mode left alone"

cleanup_sandbox

echo "  All ${scenario} PWM hand-off scenarios passed."
