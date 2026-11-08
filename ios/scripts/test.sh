#!/bin/bash
set -euo pipefail
ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"

# CLT includes Swift Testing, but SwiftPM does not automatically add its search path.
if [[ -d "$testing_frameworks/Testing.framework" && ! -d "$testing_frameworks/XCTest.framework" ]]; then
  swift test --package-path "$ios_dir/FlowCore" --disable-xctest \
    -Xswiftc "-F$testing_frameworks" -Xlinker "-F$testing_frameworks" \
    -Xlinker -rpath -Xlinker "$testing_frameworks" "$@"
else
  swift test --package-path "$ios_dir/FlowCore" "$@"
fi
