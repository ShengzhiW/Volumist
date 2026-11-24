#!/bin/zsh
# Builds the Volumist driver (universal, ad-hoc signed) and, with --test, runs its tests.
#   Driver/build.sh          -> Driver/build/VolumistDriver.driver
#   Driver/build.sh --test   also builds and runs the driver's and the app engine's tests
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
mkdir -p $OUT
rm -rf $OUT/VolumistDriver.driver $OUT/DriverTests $OUT/EngineTests $OUT/trace

DRIVER=$OUT/VolumistDriver.driver
mkdir -p $DRIVER/Contents/MacOS
cp Info.plist $DRIVER/Contents/Info.plist
clang -bundle -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  -fvisibility=hidden -framework CoreAudio -framework CoreFoundation \
  -o $DRIVER/Contents/MacOS/VolumistDriver VolumistDriver.c
codesign --force --sign - $DRIVER 2>/dev/null
echo "Built $PWD/$DRIVER"

if [[ "${1:-}" == "--test" ]]; then
  clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -mmacosx-version-min=15.0 \
    -framework CoreAudio -framework CoreFoundation -o $OUT/DriverTests Tests/DriverTests.c
  ./$OUT/DriverTests $DRIVER
  clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -mmacosx-version-min=15.0 -I. \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
    -o $OUT/EngineTests Tests/EngineTests.c ../Volumist/Engine/VolumistEngine.c
  ./$OUT/EngineTests
fi
