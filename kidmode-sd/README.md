# Kid Mode for Onion OS

A fullscreen, favorites-only launcher that locks a Miyoo Mini / Mini+ so a
young child can use it unsupervised. Requires **Onion OS 4.3 or newer**
(needs the `.tmp_update/startup/` hook directory).

- Boots straight into a big-tile carousel of **favorites only** — box art,
  big label, left/right to browse, **A** to play.
- Exiting a game returns to the kid launcher, **never** to Onion's MainUI.
- **Arm** from the Apps tab ("Kid Mode"). First arm asks you to set a 4-digit
  PIN on-device.
- **Unlock** from inside the kid UI: hold **SELECT+START for 3 seconds**
  (a progress bar appears), enter the PIN. Correct PIN returns to normal
  Onion — no reboot needed in either direction.
- Survives reboots: the mode flag lives on the SD card.
- While armed, RetroArch's settings are hidden (kiosk mode) so the in-game
  menu can't be used to change cores/shaders/mappings. Restored on unlock.
- **Play timer**: every arm asks how long (OFF / 5-50 min in 5-min steps,
  default OFF). A small remaining-time chip sits in the top-left corner
  during gameplay, warning badges appear at 3/2/1 minutes left, and at zero
  the game is asked to quit gracefully (Onion's auto-save snapshots the
  exact spot, so nothing is lost) before a friendly "Time's up!" screen.
  The timer counts actual play time — sleeping pauses it and rebooting
  doesn't reset it.
- **Parent menu** behind the PIN: Exit Kid Mode, +5 minutes today, or
  change the daily timer.
- Optional: a "Kid Mode" entry in Onion's Favorites tab (off by default —
  it confused MainUI's search results on some setups; opt in with
  `"fav_shortcut": true` in `kidmode.json`).

## How it works (design notes)

**Nothing on the SD card is moved or renamed.** Kid Mode is a flag file plus
an interception point:

- `/mnt/SDCARD/.kidmode` — flag file. Present = armed.
- `.tmp_update/startup/kidmode_boot.sh` — Onion runs everything in the
  startup folder *before* launching MainUI. When armed, this blocks in the
  kid launcher loop, so MainUI simply never starts until the PIN unlock
  removes the flag and the script returns. (The hook is installed there
  automatically from `App/KidsMode/kidmode_boot.sh` on first arm — you
  never edit `.tmp_update` by hand.)
- `App/KidsMode/bin/kidui` — small SDL app (built with Onion's toolchain)
  that renders the carousel and the PIN pad. It reads Onion's own favorites
  file (`Roms/favourite.json`), so adding/removing favorites in normal Onion
  automatically updates the kid launcher.
- `App/KidsMode/kid_mode_loop.sh` — launches the selected game exactly the
  way Onion's `runtime.sh` does (same command format, per-game core
  overrides, play-activity tracking, V4 560p handling, save/resume
  behavior), and handles clean shutdown when the power button is used
  mid-session.

The only mutated file is `RetroArch/.retroarch/retroarch.cfg` (kiosk lock,
applied on arm) — a backup is taken first and restored on unlock.

## Install

Copy the `App/KidsMode/` folder into the `App/` folder on the SD card, so
you end up with `/mnt/SDCARD/App/KidsMode/`. That's it — the boot hook
self-installs the first time you arm Kid Mode.

Make sure `App/KidsMode/bin/kidui` is present (it is committed to this
folder by the `Build Kid Mode UI` GitHub workflow; see "Rebuilding" below).

## Using it

1. In normal Onion, favorite the games your kid should see (★).
2. Apps tab → **Kid Mode**. First time: set + confirm a 4-digit PIN with the
   d-pad. The device immediately switches to the kid launcher.
3. Hand it over. Browsing: left/right. Play: A. Everything else does nothing.
4. Parent access: hold **SELECT+START ~3 s** until the PIN screen appears,
   dial the PIN (up/down changes a digit, left/right moves), press A.
   A wrong PIN silently returns to the carousel. A correct PIN opens the
   **parent menu**: *Exit Kid Mode*, *+5 minutes today*, *Timer*
   (left/right in 5-minute steps, OFF-50), *Back*.
5. Every arm starts with the timer picker (default OFF). With a timer on,
   the kid sees a small "N min" chip on the carousel and in the top-left
   corner during games, gets 3/2/1-minute badges, and lands on "Time's
   up!" at zero — where the SELECT+START menu lets you grant +5 minutes
   on the spot.

### Changing / resetting the PIN

The PIN is stored salted+hashed in `App/KidsMode/kidmode.json`. To set a new
one from a computer, edit that file to:

```json
{ "pin_hash": "", "pin_salt": "", "pin_plain": "1234" }
```

The plaintext PIN is accepted immediately and re-hashed (and the plaintext
cleared) the next time Kid Mode runs.

## Recovery / rollback

Any of these from a computer fixes any broken state — nothing else is
modified on the card:

- **Disarm:** delete `/mnt/SDCARD/.kidmode` → next boot is normal Onion.
- **Remove entirely:** also delete
  `/mnt/SDCARD/.tmp_update/startup/kidmode_boot.sh`,
  `/mnt/SDCARD/App/KidsMode/`, and the "Kid Mode" favorite
  (press X on it in Onion, or edit `Roms/favourite.json`).
- **RetroArch settings stuck hidden:** copy
  `App/KidsMode/retroarch.cfg.kidmode-backup` over
  `RetroArch/.retroarch/retroarch.cfg` (only exists while armed).
- **Reset today's play time:** delete `App/KidsMode/timer_state.txt`
  (day / used seconds / bonus seconds).

Fail-safes built in: if the kid UI binary is missing or crashes 3 times in a
row, Kid Mode disarms itself and boots normal Onion rather than brick-loop.
A log is written to `.tmp_update/logs/kidmode.log`.

## Test plan

1. **Install, don't arm, reboot** → device must boot normal Onion,
   unchanged (hook is a no-op without the flag).
2. **Arm from Apps tab** → PIN setup appears; after confirming, carousel
   shows exactly your favorites with box art.
3. **Launch a game, exit it** (RetroArch quick menu → Quit) → returns to the
   carousel, not MainUI.
4. **Reboot while armed** → boots into the carousel directly.
5. **Power off mid-game (long power press), boot again** → game resumes
   (auto-save intact), and exiting returns to the carousel.
6. **Wrong PIN** → silently returns to carousel. **Right PIN** → "Unlocked!"
   then normal Onion, RetroArch settings visible again.
7. **Empty favorites** (arming is blocked, but if favorites are removed
   while armed) → friendly "No games yet" screen; SELECT+START unlock still
   works.
8. **Recovery:** while armed, delete `.kidmode` from a computer → boots
   normal Onion.
9. **Timer:** set *Timer per day: 5 min* in the parent menu, start a game →
   badges at 3/2/1 minutes, game quits at zero into "Time's up!", and
   relaunching the game after +5 minutes resumes exactly where it stopped.
10. **Timer persistence:** reboot after time is up → still "Time's up!"
    (no budget reset until the next day).

## Rebuilding the kid UI binary

Source lives in `src/kidsMode/` in this repo. Build with Onion's toolchain:

```sh
docker run --rm -v "$PWD":/root/workspace aemiii91/miyoomini-toolchain:latest \
  /bin/bash -c "source /root/.bashrc; cd src/kidsMode && make"
cp src/kidsMode/kidui kidmode-sd/App/KidsMode/bin/kidui
```

or push a change under `src/kidsMode/` to the branch — the
`Build Kid Mode UI` workflow builds it and commits the binary here.

## v2 hardening (designed, not built)

A determined kid can still escape by holding the power button (force
shutdown) — on next boot the device re-enters Kid Mode, so the loop holds,
but sleep/shutdown itself can't be blocked from a script: the power button
is handled by the `keymon` daemon (`src/keymon/keymon.c`). v2 would patch
`keymon` to check for `/mnt/SDCARD/.kidmode` and suppress or debounce power
events while armed. The flag-file contract in `kid_mode_loop.sh` is the
integration point; no other changes needed.
