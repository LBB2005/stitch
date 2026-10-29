#!/bin/zsh
# Regenerates the project and runs the unit tests, printing only what matters.
set -o pipefail
cd "${0:A:h}/.."
xcodegen generate >/dev/null || exit 1
xcodebuild -scheme Stitch -destination 'platform=macOS' -derivedDataPath build/DerivedData test "$@" 2>&1 \
  | grep -E "error:|warning: .*\.swift|: error|failed|XCTAssert|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" \
  | grep -v "linkd" | awk '!seen[$0]++'
