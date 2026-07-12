#!/bin/sh
# Kid Mode boot hook — runs from /mnt/SDCARD/.tmp_update/startup/ before
# Onion launches MainUI (see runtime.sh "Startup scripts"). If the Kid Mode
# flag is present this blocks here in the kid launcher loop; MainUI only
# starts after a successful PIN unlock removed the flag.
#
# Recovery from a computer: delete /mnt/SDCARD/.kidmode (or this file) and
# the device boots normal Onion again.

flagfile=/mnt/SDCARD/.kidmode
looper=/mnt/SDCARD/App/KidsMode/kid_mode_loop.sh

[ -f "$flagfile" ] || exit 0

if [ -f "$looper" ]; then
    sh "$looper" run
else
    # App folder missing — fail open so the device stays usable
    rm -f "$flagfile"
fi
