#!/usr/bin/env bash
# Run every ghOSt test. Fast; needs no Docker and no ARM toolchain.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

for suite in static-checks.sh units-test.sh boot-fetch-test.sh pack-image-test.sh panel-test.sh launcher-test.sh wifi-import-test.sh; do
    echo "══════════════════════════════════════════"
    echo "  $suite"
    echo "══════════════════════════════════════════"
    if bash "$DIR/$suite"; then
        echo
    else
        fail=1
        echo "*** $suite FAILED"
        echo
    fi
done

if (( fail == 0 )); then
    echo "ALL TEST SUITES PASSED"
else
    echo "TEST SUITES FAILED"
    exit 1
fi
