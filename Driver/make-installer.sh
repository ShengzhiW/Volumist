#!/bin/zsh
# Builds double-click installers for the Volumist driver:
#   build/Install Volumist Driver.pkg    copies it into /Library/Audio/Plug-Ins/HAL
#   build/Uninstall Volumist Driver.pkg  removes it
# Installing also removes the phase-0 spike driver if present. Both restart Core Audio
# afterwards, so all sound cuts out for a moment.
set -euo pipefail
export COPYFILE_DISABLE=1
cd "$(dirname "$0")"
./build.sh --test

WORK=build/pkg
rm -rf $WORK
mkdir -p $WORK/root/Library/Audio/Plug-Ins/HAL $WORK/install-scripts $WORK/uninstall-scripts
ditto --norsrc --noextattr --noqtn build/VolumistDriver.driver $WORK/root/Library/Audio/Plug-Ins/HAL/VolumistDriver.driver

cat > $WORK/install-scripts/postinstall <<'EOF'
#!/bin/sh
# Replace the throwaway spike driver, if it's still installed.
/bin/rm -rf /Library/Audio/Plug-Ins/HAL/VolumistSpike.driver
/usr/sbin/pkgutil --forget app.volumist.spike.driver >/dev/null 2>&1 || true
/usr/bin/killall coreaudiod 2>/dev/null || true
exit 0
EOF

cat > $WORK/uninstall-scripts/postinstall <<'EOF'
#!/bin/sh
/bin/rm -rf /Library/Audio/Plug-Ins/HAL/VolumistDriver.driver
/usr/sbin/pkgutil --forget app.volumist.driver >/dev/null 2>&1 || true
/usr/bin/killall coreaudiod 2>/dev/null || true
exit 0
EOF
chmod +x $WORK/install-scripts/postinstall $WORK/uninstall-scripts/postinstall

pkgbuild --root $WORK/root --install-location / --ownership recommended \
  --identifier app.volumist.driver --version 1.1 \
  --scripts $WORK/install-scripts "build/Install Volumist Driver.pkg"
pkgbuild --nopayload --identifier app.volumist.driver.uninstall --version 1.1 \
  --scripts $WORK/uninstall-scripts "build/Uninstall Volumist Driver.pkg"
rm -rf $WORK

echo "Installers are in $PWD/build (the app can also install the driver itself: Settings > General)"
