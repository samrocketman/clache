#!/bin/sh

if ! (
  grep Alpine /etc/os-release
) > /dev/null 2>&1; then
  echo 'ERROR: this test script is meant to be run from alpine Linux.' >&2
  exit 1
fi

result=0

if ! (
  set -e
  ! ./clache.sh -c README.md > /dev/null
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine to fail.' >&2
  result=1
else
  echo "PASSED: default alpine failed." >&2
fi

if ! (
  set -e
  apk add --no-cache bash
  ./clache.sh -s -c README.md 2>&1 > /dev/null | grep "^ERROR: tr"
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash to fail due to no coreutils.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash failed.' >&2
fi
if ! (
  set -e
  apk add --no-cache coreutils
  ./clache.sh -s -c README.md 2>&1 > /dev/null | grep "^ERROR: tar"
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash and coreutils to fail without GNU tar.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash and coreutils failed.' >&2
fi
if ! (
  set -e
  apk add --no-cache tar
  ./clache.sh -s -c README.md > /tmp/file.tar
  ./clache.sh -e README.md < /tmp/file.tar
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash, coreutils, and GNU tar to succeed.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash, coreutils, and GNU tar succeeded.' >&2
fi
if ! (
  set -e
  apk add --no-cache xxhash
  ./clache.sh -s -c README.md > /tmp/file.tar
  ./clache.sh -e README.md < /tmp/file.tar
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash, coreutils, GNU tar, and xxhash to succeed.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash, coreutils, GNU tar, and xxhash succeeded.' >&2
fi

################################################################################
# Corruption tests
################################################################################
echo hello > /tmp/file
x="$PWD"
cd /tmp
"$x"/clache.sh -H 1 -c file > file.tar 2>/dev/null
cd "$x"

# fake algorithm
dd if=/tmp/file.tar bs=599 count=1 iflag=fullblock status=none of=/tmp/head
echo '12 cl_alg=8' > /tmp/body
dd if=/tmp/file.tar bs=611 skip=1 iflag=fullblock status=none of=/tmp/tail
cat /tmp/head /tmp/body /tmp/tail > /tmp/bad-alg.tar

if ! (
  set -e
  ./clache.sh -e < /tmp/bad-alg.tar 2>&1 > /dev/null | grep '^ERROR: could not determine checksum algorithm.'
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected bad algorithm to fail.' >&2
  result=1
else
  echo 'PASSED: Fail on bad algorithm.' >&2
fi

# header bytes reaching outside of its bounds
dd if=/tmp/file.tar bs=599 count=1 iflag=fullblock status=none of=/tmp/head
echo '123 malcs=1' > /tmp/body
dd if=/tmp/file.tar bs=611 skip=1 iflag=fullblock status=none of=/tmp/tail
cat /tmp/head /tmp/body /tmp/tail > /tmp/malicious.tar

if ! (
  set -e
  ./clache.sh -e < /tmp/malicious.tar 2>&1 > /dev/null | grep '^ERROR: A malicious pax header'
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected a malicious pax header reaching out of bounds to fail.' >&2
  result=1
else
  echo 'PASSED: Fail on pax header reaching out of bounds.' >&2
fi

# fake hash utility
dd if=/tmp/file.tar bs=592 count=1 iflag=fullblock status=none of=/tmp/head
echo 'fakers' > /tmp/body
dd if=/tmp/file.tar bs=599 skip=1 iflag=fullblock status=none of=/tmp/tail
cat /tmp/head /tmp/body /tmp/tail > /tmp/bad-utl.tar

if ! (
  set -e
  ./clache.sh -e < /tmp/bad-utl.tar 2>&1 > /dev/null | grep '^ERROR: could not determine checksum algorithm.'
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected bad hash utility to fail.' >&2
  result=1
else
  echo 'PASSED: Fail on bad hash utility.' >&2
fi

exit "$result"
