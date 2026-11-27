# The app's flash app

`flashapp.bin` is Paramix Studio's flash app (third_party/paramix-studio/flash, GPL-3.0-or-later)
with one more command, `restart.patch`: type 16 answers and then restarts the toy into its own
firmware, so the reset button is not needed to leave the flash screen. It first asks the core
for a reset (AIRCR SYSRESETREQ); where that does nothing it switches the watchdog on and stops
feeding it. `tool/sync_paramix.sh` puts this build into the app.

Build (clang, ld.lld, llvm-objcopy; the unpatched source gives the Studio's file byte for byte):

    cp -r third_party/paramix-studio/flash /tmp/fa && cd /tmp/fa
    patch -p0 src/fw.c < "$OLDPWD/tool/flashapp/restart.patch" && sh src/build.sh
