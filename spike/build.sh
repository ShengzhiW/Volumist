#!/bin/zsh
# Builds the spike: the driver bundle (universal, ad-hoc signed) and the two test programs.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
mkdir -p $OUT
# Remove only what this script rebuilds, so the installer packages survive.
rm -rf $OUT/VolumistSpike.driver $OUT/spike-host $OUT/spike-tone

DRIVER=$OUT/VolumistSpike.driver
mkdir -p $DRIVER/Contents/MacOS
cp driver/Info.plist $DRIVER/Contents/Info.plist
clang -bundle -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  -framework CoreAudio -framework CoreFoundation \
  -o $DRIVER/Contents/MacOS/VolumistSpike driver/VolumistSpikeDriver.c
codesign --force --sign - $DRIVER

for tool in spike-host spike-tone; do
  clang -O2 -Wall -Wextra -mmacosx-version-min=15.0 -framework CoreAudio -framework CoreFoundation \
    -o $OUT/$tool host/$tool.c
done

echo "Built $PWD/$DRIVER, $OUT/spike-host, $OUT/spike-tone"
