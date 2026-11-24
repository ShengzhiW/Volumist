#!/bin/zsh
# Builds double-click installers for the spike driver:
#   build/Install Volumist Spike.pkg    copies the driver into /Library/Audio/Plug-Ins/HAL
#   build/Uninstall Volumist Spike.pkg  removes it
# Both restart Core Audio afterwards (sound cuts out for a moment).
set -euo pipefail
export COPYFILE_DISABLE=1  # keep macOS metadata (._ files) out of the packages
cd "$(dirname "$0")"
./build.sh

WORK=build/pkg
rm -rf $WORK
mkdir -p $WORK/root/Library/Audio/Plug-Ins/HAL $WORK/install-scripts $WORK/uninstall-scripts
ditto --norsrc --noextattr --noqtn build/VolumistSpike.driver $WORK/root/Library/Audio/Plug-Ins/HAL/VolumistSpike.driver

cat > $WORK/install-scripts/postinstall <<'EOF'
#!/bin/sh
/usr/bin/killall coreaudiod 2>/dev/null || true
exit 0
EOF

cat > $WORK/uninstall-scripts/postinstall <<'EOF'
#!/bin/sh
/bin/rm -rf /Library/Audio/Plug-Ins/HAL/VolumistSpike.driver
/usr/sbin/pkgutil --forget app.volumist.spike.driver >/dev/null 2>&1 || true
/usr/bin/killall coreaudiod 2>/dev/null || true
exit 0
EOF
chmod +x $WORK/install-scripts/postinstall $WORK/uninstall-scripts/postinstall

pkgbuild --root $WORK/root --install-location / --ownership recommended \
  --identifier app.volumist.spike.driver --version 0.1 \
  --scripts $WORK/install-scripts "build/Install Volumist Spike.pkg"

pkgbuild --nopayload --identifier app.volumist.spike.uninstall --version 0.1 \
  --scripts $WORK/uninstall-scripts "build/Uninstall Volumist Spike.pkg"

rm -rf $WORK
echo "Installers are in $PWD/build"
