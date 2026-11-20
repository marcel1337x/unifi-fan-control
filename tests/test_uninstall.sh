#!/bin/bash
###############################################################################
# Uninstaller behavior tests — sandbox every path the root-owned script writes.
###############################################################################
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(dirname "$0")/lib/harness.sh"

UNINSTALLER="$REPO_ROOT/uninstall.sh"
REAL_RM=$(command -v rm)
UNINSTALL_OUTPUT=""

trap teardown_sandbox EXIT

install_stubs() {
    cat >"$SANDBOX/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
STUB
    chmod +x "$SANDBOX/bin/id"

    cat >"$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/systemctl.log"
STUB
    chmod +x "$SANDBOX/bin/systemctl"

    cat >"$SANDBOX/bin/rm" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        /etc/systemd/system/fan-control.service|/var/run/fan-control.pid|/data/fan-control)
            exit 1
            ;;
    esac
done
exec "$REAL_RM" "\$@"
STUB
    chmod +x "$SANDBOX/bin/rm"
}

prepare_case() {
    cleanup_sandbox
    setup_sandbox
    install_stubs

    export FAN_CONTROL_HWMON_BASE="$SANDBOX/hwmon"
    export FAN_CONTROL_INSTALL_DIR="$SANDBOX/install"
    export FAN_CONTROL_SERVICE_FILE="$SANDBOX/systemd/fan-control.service"
    export FAN_CONTROL_DATA_ROOT="$SANDBOX/data"

    rm -rf "$FAN_CONTROL_HWMON_BASE"
    mkdir -p "$FAN_CONTROL_HWMON_BASE" "$FAN_CONTROL_INSTALL_DIR" "$FAN_CONTROL_DATA_ROOT" \
        "$(dirname "$FAN_CONTROL_SERVICE_FILE")" "$(dirname "$FAN_CONTROL_PID_FILE")"
    printf 'installed data\n' >"$FAN_CONTROL_INSTALL_DIR/config"
    printf '#!/bin/bash\n' >"$FAN_CONTROL_INSTALL_DIR/fan-control.sh"
    printf 'service\n' >"$FAN_CONTROL_SERVICE_FILE"
    printf '1234\n' >"$FAN_CONTROL_PID_FILE"
}

run_uninstaller() {
    if ! UNINSTALL_OUTPUT=$(bash "$UNINSTALLER" 2>&1); then
        printf '%s\n' "$UNINSTALL_OUTPUT" >&2
        fail "uninstall.sh exited unsuccessfully"
    fi
}

assert_removed() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "expected removal of $path"
}

assert_system_files_removed() {
    assert_removed "$FAN_CONTROL_INSTALL_DIR"
    assert_removed "$FAN_CONTROL_SERVICE_FILE"
    assert_removed "$FAN_CONTROL_PID_FILE"
}

test_class_directory_pwm_reset() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0"
    printf '127\n' >"$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1"

    run_uninstaller

    assert_eq "$(cat "$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1")" "180" \
        "strategy 1 PWM reset: "
    assert_system_files_removed
    printf '✓ Strategy 1 reset class-directory PWM and removed sandbox paths\n'
}

test_raw_device_pwm_reset() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0" "$SANDBOX/raw-device"
    ln -s "$SANDBOX/raw-device" "$FAN_CONTROL_HWMON_BASE/hwmon0/device"
    printf '191\n' >"$SANDBOX/raw-device/pwm1"

    run_uninstaller

    assert_eq "$(cat "$SANDBOX/raw-device/pwm1")" "180" \
        "strategy 2 PWM reset: "
    assert_system_files_removed
    printf '✓ Strategy 2 reset raw-device PWM and removed sandbox paths\n'
}

test_no_pwm_devices_warns_cleanly() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0"

    run_uninstaller

    assert_contains "$UNINSTALL_OUTPUT" "Warning: No PWM devices found to reset"
    assert_system_files_removed
    printf '✓ No-PWM fixture warned and completed cleanly\n'
}

test_git_checkout_install_dir_kept() {
    prepare_case
    # No override: the install dir must come from the installed unit's WorkingDirectory.
    unset FAN_CONTROL_INSTALL_DIR
    local checkout="$SANDBOX/work/unifi-fan-control"
    mkdir -p "$checkout"
    mv "$SANDBOX/install/config" "$checkout/config"
    printf 'WorkingDirectory=%s\nExecStart=%s/fan-control.sh\n' "$checkout" "$checkout" >"$FAN_CONTROL_SERVICE_FILE"
    FAN_CONTROL_INSTALL_DIR="$checkout" # for the assertions below only
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0"
    # Worktree-style checkout: .git is a file, not a directory.
    printf 'gitdir: /elsewhere\n' >"$FAN_CONTROL_INSTALL_DIR/.git"
    printf '0\n' >"$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1"
    printf '60\n' >"$FAN_CONTROL_INSTALL_DIR/temp_state"
    printf '91\n' >"$FAN_CONTROL_INSTALL_DIR/optimal_pwm"
    printf 'uncommitted work\n' >"$FAN_CONTROL_INSTALL_DIR/fan-control.sh"

    run_uninstaller

    assert_removed "$FAN_CONTROL_INSTALL_DIR/config"
    assert_removed "$FAN_CONTROL_INSTALL_DIR/temp_state"
    assert_removed "$FAN_CONTROL_INSTALL_DIR/optimal_pwm"
    assert_removed "$FAN_CONTROL_SERVICE_FILE"
    [[ -e "$FAN_CONTROL_INSTALL_DIR/.git" ]] || fail "git checkout was removed"
    assert_eq "$(cat "$FAN_CONTROL_INSTALL_DIR/fan-control.sh")" "uncommitted work" "checkout file: "
    printf '✓ Git checkout install dir kept, runtime state removed\n'
}

test_hardware_controlled_pwm_left_alone() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0"
    printf '120\n' >"$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1"
    printf '2\n' >"$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1_enable"

    run_uninstaller

    assert_eq "$(cat "$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1")" "120" "automatic-mode PWM: "
    assert_contains "$UNINSTALL_OUTPUT" "under hardware control"
    printf '✓ Automatic-mode channel left under hardware control\n'
}

test_unsafe_install_dir_not_removed() {
    local target
    for target in data-root no-daemon; do
        prepare_case
        unset FAN_CONTROL_INSTALL_DIR
        if [[ "$target" == data-root ]]; then
            target="$FAN_CONTROL_DATA_ROOT"
            printf '#!/bin/bash\n' >"$target/fan-control.sh"
        else
            target="$SANDBOX/not-fan-control"
            mkdir -p "$target"
        fi
        printf 'keep\n' >"$target/precious"
        # The "-" prefix (ignore if missing) is valid systemd syntax and must be stripped.
        printf 'WorkingDirectory=-%s\n' "$target" >"$FAN_CONTROL_SERVICE_FILE"

        run_uninstaller

        assert_eq "$(cat "$target/precious")" "keep" "unsafe dir contents: "
        assert_contains "$UNINSTALL_OUTPUT" "does not look like a fan-control install"
    done
    printf '✓ Data root and non-install dirs from the unit are not removed\n'
}

case "${UNINSTALL_CASE:-all}" in
    all)
        test_class_directory_pwm_reset
        test_raw_device_pwm_reset
        test_no_pwm_devices_warns_cleanly
        test_git_checkout_install_dir_kept
        test_unsafe_install_dir_not_removed
        test_hardware_controlled_pwm_left_alone
        ;;
    unsafe)
        test_unsafe_install_dir_not_removed
        ;;
    checkout)
        test_git_checkout_install_dir_kept
        ;;
    class)
        test_class_directory_pwm_reset
        ;;
    device)
        test_raw_device_pwm_reset
        ;;
    none)
        test_no_pwm_devices_warns_cleanly
        ;;
    *)
        fail "unknown UNINSTALL_CASE: ${UNINSTALL_CASE}"
        ;;
esac
