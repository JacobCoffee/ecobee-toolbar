#!/usr/bin/env bash
# Run the test suite. With only the Command Line Tools installed, Swift Testing
# lives outside the default search paths, so point the compiler at it.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
    exec swift test \
        -Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
