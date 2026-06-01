#!/bin/bash

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:-}"' EXIT
result=0
# tar tests require real paths and no symlinks within the path
TMP_DIR="$(cd "$TMP_DIR"; pwd -P)"

if ! (
  set -euo pipefail
  shellcheck clache.sh docs/*.sh
) &> /dev/null; then
    echo 'Test Failed: shellcheck clache.sh' >&2
    # fast fail
    exit 1
else
  echo 'PASSED: shellcheck' >&2
fi

echo hello > "$TMP_DIR"/afile

for x in 1 256; do
  if ! (
    set -euo pipefail
    ./clache.sh --sha "$x" -c -n "$TMP_DIR"/afile README.md > "$TMP_DIR/file.tar"
    ./clache.sh -s -e -n < "$TMP_DIR/file.tar"
  ) &> /dev/null; then
    echo "Test Failed: shasum --sha $x" >&2
    result=1
  else
    echo "PASSED: shasum --sha $x" >&2
  fi
done

echo 'Checking for docker.' >&2
if {
  type -P docker &&
  timeout 30 docker run --rm alpine /bin/true
} &> /dev/null; then
  echo 'Running docker-based tests.' >&2
  docker run --rm -v "$PWD:/mnt" -w /mnt alpine ./docs/alpine-tests.sh
else
  echo "SKIPPED: docker-based alpine tests due to no docker." >&2
fi

if [ "${result}" = 0 ]; then
  echo 'All tests passed.' >&2
fi
exit "$result"
