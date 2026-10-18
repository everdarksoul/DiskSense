#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$clt" && -f "$clt/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" ]]; then
  swift test --scratch-path .build/scan-fix --disable-xctest \
    -Xswiftc -load-plugin-library -Xswiftc "$clt/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    -Xlinker -rpath -Xlinker "$clt/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$clt/Library/Developer/usr/lib" "$@"
else
  swift test "$@"
fi
