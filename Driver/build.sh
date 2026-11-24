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
  # Test build of the driver: own socket, and it accepts the test program instead of Volumist.
  TESTING=$OUT/VolumistDriverTesting.driver
  rm -rf $TESTING && mkdir -p $TESTING/Contents/MacOS && cp Info.plist $TESTING/Contents/Info.plist
  clang -bundle -O2 -Wall -Wextra -Werror -DVD_TESTING -mmacosx-version-min=15.0 -fvisibility=hidden \
    -framework CoreAudio -framework CoreFoundation -o $TESTING/Contents/MacOS/VolumistDriver VolumistDriver.c
  clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -mmacosx-version-min=15.0 -I. \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
    -o $OUT/DriverTests Tests/DriverTests.c ../Volumist/Engine/VolumistEngine.c
  ./$OUT/DriverTests $TESTING
  clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -mmacosx-version-min=15.0 -I. \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
    -o $OUT/EngineTests Tests/EngineTests.c ../Volumist/Engine/VolumistEngine.c
  ./$OUT/EngineTests
fi
