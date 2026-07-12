#!/bin/sh
# ---------------------------------------------------------------------------
# Kid Mode for Onion OS — arming, play loop, and unlock logic.
#
# The device is locked to a fullscreen favorites-only launcher (kidui).
# Exiting a game always returns to the launcher, never to MainUI.
#
# Usage:
#   kid_mode_loop.sh arm    arm Kid Mode (first run asks to set a PIN),
#                           then enter the loop; called by the Apps-tab app
#   kid_mode_loop.sh run    enter the loop if armed; called by the startup
#                           hook (.tmp_update/startup/kidmode_boot.sh)
#
# Mode flag: /mnt/SDCARD/.kidmode  (present = armed; delete it from a
# computer to force-disable Kid Mode)
#
# v2 HARDENING HOOK: while armed, a determined kid can still force-shutdown
# with a long power press (keymon handles power directly). To harden, patch
# src/keymon/keymon.c to ignore/limit power events while /mnt/SDCARD/.kidmode
# exists. Out of scope for v1 by design.
# ---------------------------------------------------------------------------

sysdir=/mnt/SDCARD/.tmp_update
miyoodir=/mnt/SDCARD/miyoo
appdir=/mnt/SDCARD/App/KidsMode

kidui_bin="$appdir/bin/kidui"
configfile="$appdir/kidmode.json"
flagfile=/mnt/SDCARD/.kidmode
favfile=/mnt/SDCARD/Roms/favourite.json
racfg=/mnt/SDCARD/RetroArch/.retroarch/retroarch.cfg
rabackup="$appdir/retroarch.cfg.kidmode-backup"
uiout=/tmp/kidmode_ui_out
logfile=/mnt/SDCARD/.tmp_update/logs/kidmode.log

export LD_LIBRARY_PATH="/lib:/config/lib:$miyoodir/lib:$sysdir/lib:$sysdir/lib/parasyte"
export PATH="$sysdir/bin:$PATH"

log() {
    mkdir -p "$(dirname "$logfile")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$logfile"
}

# --------------------------- PIN handling ----------------------------------

hash_string() {
    if command -v sha256sum > /dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v openssl > /dev/null 2>&1; then
        printf '%s' "$1" | openssl dgst -sha256 2> /dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

make_salt() {
    if [ -r /dev/urandom ]; then
        dd if=/dev/urandom bs=8 count=1 2> /dev/null | od -An -tx1 | tr -d ' \n'
    else
        printf '%s' "$(date +%s)$$"
    fi
}

config_get() {
    [ -f "$configfile" ] || return 1
    jq -r --arg k "$1" '.[$k] // empty' "$configfile" 2> /dev/null
}

is_4_digits() {
    case "$1" in
        [0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

store_pin() {
    new_pin="$1"
    salt="$(make_salt)"
    hash="$(hash_string "${salt}${new_pin}" 2> /dev/null || true)"
    tmpcfg=/tmp/kidmode_config.$$
    if [ -n "$hash" ]; then
        jq -n --arg h "$hash" --arg s "$salt" \
            '{pin_hash: $h, pin_salt: $s, pin_plain: ""}' > "$tmpcfg"
    else
        # No hashing tool available — plaintext fallback (threat model: child)
        jq -n --arg p "$new_pin" \
            '{pin_hash: "", pin_salt: "", pin_plain: $p}' > "$tmpcfg"
    fi
    mv -f "$tmpcfg" "$configfile"
    sync
    log "PIN updated."
}

has_pin() {
    [ -n "$(config_get pin_hash)" ] && return 0
    is_4_digits "$(config_get pin_plain)"
}

# If the parent wrote a plaintext PIN into kidmode.json, hash it in place.
migrate_plain_pin() {
    plain="$(config_get pin_plain)"
    if is_4_digits "$plain"; then
        store_pin "$plain"
    fi
}

verify_pin() {
    entered="$1"
    is_4_digits "$entered" || return 1

    stored_plain="$(config_get pin_plain)"
    if is_4_digits "$stored_plain" && [ "$entered" = "$stored_plain" ]; then
        return 0
    fi

    stored_hash="$(config_get pin_hash)"
    stored_salt="$(config_get pin_salt)"
    if [ -n "$stored_hash" ]; then
        entered_hash="$(hash_string "${stored_salt}${entered}" 2> /dev/null || true)"
        [ -n "$entered_hash" ] && [ "$entered_hash" = "$stored_hash" ] && return 0
    fi

    return 1
}

run_pin_entry() {
    # $1 = title; echoes the PIN on success
    rm -f "$uiout"
    "$kidui_bin" --set-pin -t "$1" > "$uiout"
    [ $? -eq 3 ] || return 1
    [ "$(sed -n 1p "$uiout")" = "PIN" ] || return 1
    entered="$(sed -n 2p "$uiout")"
    rm -f "$uiout"
    is_4_digits "$entered" || return 1
    printf '%s\n' "$entered"
}

ensure_pin() {
    migrate_plain_pin
    if has_pin; then
        return 0
    fi

    pin1="$(run_pin_entry "Set Kid Mode PIN")" || return 1
    pin2="$(run_pin_entry "Confirm PIN")" || return 1

    if [ "$pin1" != "$pin2" ]; then
        infoPanel -t "Kid Mode" -m "PINs did not match.\nTry again." --auto
        return 1
    fi

    store_pin "$pin1"
    return 0
}

# ----------------------- RetroArch kiosk lock ------------------------------
# While armed, hide RetroArch's settings so the in-game menu can't be used to
# change cores, shaders, mappings, etc. Restored from backup on unlock.
# (Approach borrowed from OnionUI PR #1910.)

ra_set() {
    if grep -q "^[[:space:]]*$1[[:space:]]*=" "$racfg" 2> /dev/null; then
        sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = \"$2\"|" "$racfg"
    else
        printf '%s = "%s"\n' "$1" "$2" >> "$racfg"
    fi
}

apply_ra_lock() {
    [ -f "$racfg" ] || return 0
    [ -f "$rabackup" ] || cp "$racfg" "$rabackup"

    ra_set kiosk_mode_enable true
    ra_set quick_menu_show_options false
    ra_set quick_menu_show_cheats false
    ra_set quick_menu_show_shaders false
    ra_set quick_menu_show_start_recording false
    ra_set quick_menu_show_start_streaming false
    for section in configuration core directory drivers file_browser input \
        latency network recording user user_interface video audio; do
        ra_set "settings_show_$section" false
    done
    sync
    log "RetroArch kiosk lock applied."
}

restore_ra_lock() {
    if [ -f "$rabackup" ]; then
        cp "$rabackup" "$racfg"
        rm -f "$rabackup"
        sync
        log "RetroArch config restored."
    fi
}

# --------------------------- shutdown handling -----------------------------
# runtime.sh's main loop normally reacts to /tmp/.offOrder; while Kid Mode
# blocks that loop we must handle it ourselves or the device won't power off
# cleanly after keymon kills a game.

check_off_order() {
    [ -f /tmp/.offOrder ] || return 0
    touch /tmp/shutting_down
    for _off_script in "$sysdir"/checkoff/*.sh; do
        [ -f "$_off_script" ] && sh "$_off_script"
    done
    bootScreen "$1" &
    sleep 1
    shutdown
    sleep 60 # never reached; wait for poweroff
}

# ----------------------------- game launch ---------------------------------

start_audioserver_if_needed() {
    if ! pgrep audioserver > /dev/null 2>&1; then
        defvol=$(/customer/app/jsonval vol | awk '{ printf "%.0f\n", 48 * (log(1 + $1) / log(10)) - 60 }')
        "$miyoodir/app/audioserver" "$defvol" &
        sleep 0.5
    fi
}

set_resolution() {
    _res_x="${1%x*}"
    _res_y="${1#*x}"
    bootScreen clear
    fbset -g "$_res_x" "$_res_y" "$_res_x" $((_res_y * 2)) 32
    killall -SIGUSR1 batmon 2> /dev/null
    killall -SIGUSR1 keymon 2> /dev/null
}

enable_ra_network_cmds() {
    # Same patch runtime.sh applies before every game (Onion features rely
    # on RetroArch network commands, e.g. save-on-shutdown).
    if [ -x "$sysdir/script/patch_ra_cfg.sh" ]; then
        cat > /tmp/onion_ra_patch.cfg <<- EOM
network_cmd_enable = "true"
EOM
        "$sysdir/script/patch_ra_cfg.sh" /tmp/onion_ra_patch.cfg
        rm -f /tmp/onion_ra_patch.cfg
    fi
}

# Build $sysdir/cmd_to_run.sh for a favorite exactly like MainUI would,
# including the per-rom core override (.game_config/<rom>.cfg).
build_game_cmd() {
    game_launch="$1"
    game_rompath="$2"

    if [ -f "$game_rompath" ]; then
        game_rompath="$(realpath "$game_rompath")"
    fi

    echo "LD_PRELOAD=$miyoodir/lib/libpadsp.so \"$game_launch\" \"$game_rompath\"" > "$sysdir/cmd_to_run.sh"

    game_ext="$(basename "$game_rompath" | awk -F. '{print tolower($NF)}')"
    game_cfg="$(dirname "$game_rompath")/.game_config/$(basename "$game_rompath" ".$game_ext").cfg"

    if [ -f "$game_cfg" ] && [ -f "$game_launch" ] &&
        grep -q '.retroarch/cores' "$game_launch"; then
        game_core=$(grep "core\b" "$game_cfg" | awk '{split($0,a,"="); print a[2]}' | awk -F'"' '{print $2}' | tr -d '\n')
        if [ -n "$game_core" ] && [ -f "/mnt/SDCARD/RetroArch/.retroarch/cores/$game_core.so" ]; then
            echo "LD_PRELOAD=$miyoodir/lib/libpadsp.so ./retroarch -v -L \".retroarch/cores/$game_core.so\" \"$game_rompath\"" > "$sysdir/cmd_to_run.sh"
        fi
    fi

    # Escape dollar signs in rom filenames, like runtime.sh does
    if echo "$game_rompath" | grep -q '\$'; then
        sed -i 's/\$/\\$/g' "$sysdir/cmd_to_run.sh"
    fi

    chmod a+x "$sysdir/cmd_to_run.sh"
}

# Run whatever is in $sysdir/cmd_to_run.sh and clean up afterwards.
# Mirrors runtime.sh launch_game: audio, LOADING splash, 560p handling on the
# Miyoo Mini V4, playActivity tracking, and the post-game SAVING splash —
# so Onion auto-save/resume keeps working unchanged.
run_game_cmd() {
    [ -f "$sysdir/cmd_to_run.sh" ] || return 1

    run_cmd="$(cat "$sysdir/cmd_to_run.sh")"
    run_rompath="$(echo "$run_cmd" | awk '{ st = index($0,"\" \""); if (st) print substr($0,st+3,length($0)-st-3)}')"
    run_launch="$(echo "$run_cmd" | awk -F'"' '{print $2}')"

    tz_value="$(cat "$sysdir/config/.tz" 2> /dev/null)"

    start_audioserver_if_needed
    enable_ra_network_cmds

    # Miyoo Mini V4 (752x560): switch resolution if this system supports it
    changed_res=0
    fullres_path="$(dirname "$run_launch")/full_resolution"
    if [ -f /tmp/new_res_available ] && [ -f "$fullres_path" ]; then
        set_resolution "$(cat /tmp/screen_resolution 2> /dev/null || echo 752x560)"
        changed_res=1
    elif [ ! -f /tmp/new_res_available ]; then
        infoPanel --message "LOADING" --persistent --romscreen &
        touch /tmp/dismiss_info_panel
        sync
    fi

    [ -n "$run_rompath" ] && playActivity start "$run_rompath"

    log "launching: $run_cmd"
    cd /mnt/SDCARD/RetroArch || cd "$appdir"
    TZ="$tz_value" sh "$sysdir/cmd_to_run.sh"
    run_retval=$?
    log "game exited with $run_retval"

    if [ "$changed_res" -eq 1 ]; then
        set_resolution "640x480"
    fi

    if [ ! -f /tmp/.offOrder ] && [ -f /tmp/.displaySavingMessage ]; then
        rm -f /tmp/.displaySavingMessage
        infoPanel --message "SAVING" --persistent --romscreen &
        touch /tmp/dismiss_info_panel
        sync
    fi

    [ -n "$run_rompath" ] && playActivity stop "$run_rompath"

    rm -f "$sysdir/cmd_to_run.sh"
    cd "$appdir" 2> /dev/null

    check_off_order "End_Save"
    return 0
}

is_game_cmd() {
    grep -q "retroarch/cores\|/../../Roms/\|/mnt/SDCARD/Roms/" "$1" 2> /dev/null
}

# ------------------------------ unlock -------------------------------------

disarm() {
    rm -f "$flagfile"
    restore_ra_lock
    rm -f "$sysdir/cmd_to_run.sh" "$uiout"
    sync
    log "Kid Mode disarmed."
    infoPanel -t "Kid Mode" -m "Unlocked!\nReturning to Onion." --auto
}

# ------------------------------ main loop ----------------------------------

cmd_run() {
    if [ ! -f "$kidui_bin" ]; then
        log "kidui binary missing; disarming."
        rm -f "$flagfile"
        sync
        return 1
    fi
    chmod a+x "$kidui_bin" 2> /dev/null

    ui_fails=0

    # A game left in cmd_to_run.sh means the device powered off mid-game:
    # relaunch it first so RetroArch auto-resume works like stock Onion.
    if [ -f "$sysdir/cmd_to_run.sh" ] && is_game_cmd "$sysdir/cmd_to_run.sh"; then
        log "resuming interrupted game"
        run_game_cmd
    fi

    while [ -f "$flagfile" ]; do
        check_off_order "End"

        # Defensive cleanup: nothing may divert the loop into GameSwitcher
        rm -f "$sysdir/.runGameSwitcher" 2> /dev/null
        pgrep keymon > /dev/null 2>&1 || keymon &

        rm -f "$uiout"
        "$kidui_bin" > "$uiout"
        ui_rc=$?

        check_off_order "End"

        case "$ui_rc" in
            0) # game selected
                [ "$(sed -n 1p "$uiout")" = "LAUNCH" ] || continue
                sel_launch="$(sed -n 2p "$uiout")"
                sel_rompath="$(sed -n 3p "$uiout")"
                [ -f "$sel_rompath" ] || continue
                build_game_cmd "$sel_launch" "$sel_rompath"
                run_game_cmd
                ui_fails=0
                ;;
            3) # PIN entered
                [ "$(sed -n 1p "$uiout")" = "PIN" ] || continue
                if verify_pin "$(sed -n 2p "$uiout")"; then
                    disarm
                    return 0
                fi
                # Wrong PIN: silently return to the grid (rate-limited)
                sleep 1
                ;;
            *) # UI crashed or won't start
                ui_fails=$((ui_fails + 1))
                log "kidui exited with unexpected code $ui_rc (fail $ui_fails/3)"
                if [ "$ui_fails" -ge 3 ]; then
                    # Fail open: a broken Kid Mode must never brick the
                    # device. Parent can re-arm after fixing the SD card.
                    infoPanel -t "Kid Mode" -m "Kid Mode UI failed.\nReturning to normal Onion." --auto
                    disarm
                    return 1
                fi
                sleep 1
                ;;
        esac
    done

    # Flag removed externally (e.g. deleted from a computer) — clean up
    restore_ra_lock
    rm -f "$sysdir/cmd_to_run.sh"
    return 0
}

cmd_arm() {
    if [ ! -f "$kidui_bin" ]; then
        infoPanel -t "Kid Mode" -m "kidui binary is missing.\nReinstall the KidsMode app." --auto
        return 1
    fi

    fav_count=0
    [ -f "$favfile" ] && fav_count=$(grep -c "rompath" "$favfile" 2> /dev/null)
    if [ "$fav_count" -eq 0 ]; then
        infoPanel -t "Kid Mode" -m "No favorites found.\nAdd some favorites first,\nthen arm Kid Mode." --auto
        return 1
    fi

    if ! ensure_pin; then
        infoPanel -t "Kid Mode" -m "PIN setup canceled.\nKid Mode was NOT armed." --auto
        return 1
    fi

    apply_ra_lock
    touch "$flagfile"
    sync
    log "Kid Mode armed."

    cmd_run
}

case "${1:-run}" in
    arm)
        cmd_arm
        ;;
    run)
        [ -f "$flagfile" ] || exit 0
        migrate_plain_pin
        cmd_run
        ;;
    *)
        echo "Usage: kid_mode_loop.sh [arm|run]" >&2
        exit 1
        ;;
esac
