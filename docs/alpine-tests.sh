#!/bin/sh

if ! (
  grep Alpine /etc/os-release
) > /dev/null 2>&1; then
  echo 'ERROR: this test script is meant to be run from alpine Linux.' >&2
  exit 1
fi

result=0
export PATH="$PWD:$PATH"
if [ -w /dev/shm ]; then
  cd /dev/shm
else
  cd /tmp
fi
pwd >&2
echo hello > file

if ! (
  set -e
  ! clache.sh -c file > /dev/null
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine to fail.' >&2
  result=1
else
  echo "PASSED: default alpine failed." >&2
fi

if ! (
  set -e
  apk add --no-cache bash
  clache.sh -s -c file 2>&1 > /dev/null | grep "^ERROR: tr"
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash to fail due to no coreutils.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash failed.' >&2
fi
if ! (
  set -e
  apk add --no-cache coreutils
  clache.sh -s -c file 2>&1 > /dev/null | grep "^ERROR: tar"
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash and coreutils to fail without GNU tar.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash and coreutils failed.' >&2
fi
if ! (
  set -e
  apk add --no-cache tar
  clache.sh -s -c file > file.tar
  clache.sh -e < file.tar
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash, coreutils, and GNU tar to succeed.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash, coreutils, and GNU tar succeeded.' >&2
fi
if ! (
  set -e
  apk add --no-cache xxhash
  clache.sh -s -c file > file.tar
  clache.sh -e < file.tar
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected default alpine with bash, coreutils, GNU tar, and xxhash to succeed.' >&2
  result=1
else
  echo 'PASSED: default alpine failed with bash, coreutils, GNU tar, and xxhash succeeded.' >&2
fi

################################################################################
# Algorithm tests
################################################################################
echo world > afile
for x in 1 2 3; do
  if ! (
    set -e
    clache.sh --xxh "$x" -c -n "$PWD/afile" file > file.tar
    clache.sh -s -e -n < file.tar
  ) > /dev/null 2>&1; then
    echo "Test Failed: --xxh $x" >&2
    result=1
  else
    echo "PASSED: --xxh $x" >&2
  fi
done

for x in 1 256; do
  if ! (
    set -x
    clache.sh --sha "$x" -c -n "$PWD/afile" file > file.tar
    clache.sh -s -e -n < file.tar
  ) > /dev/null 2>&1; then
    echo "Test Failed: sha${x}sum --sha $x" >&2
    result=1
  else
    echo "PASSED: sha${x}sum --sha $x" >&2
  fi
done

if ! (
  set -e
  clache.sh -c file > file.tar
  ! clache.sh -s -e < file.tar
) > /dev/null 2>&1; then
  echo 'Test Failed: Verifying checksums in archive without checksums should have failed.' >&2
  result=1
else
  echo "PASSED: Archive without checksums fails when checksums required." >&2
fi


################################################################################
# Corruption tests
################################################################################
clache.sh -H 1 -c file > file.tar 2>/dev/null

# fake algorithm
dd if=file.tar bs=599 count=1 iflag=fullblock status=none of=head
echo '12 cl_alg=8' > body
dd if=file.tar bs=611 skip=1 iflag=fullblock status=none of=tail
cat head body tail > bad-alg.tar

if ! (
  set -e
  clache.sh -e < bad-alg.tar 2>&1 > /dev/null | grep '^ERROR: could not determine checksum algorithm.'
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected bad algorithm to fail.' >&2
  result=1
else
  echo 'PASSED: Fail on bad algorithm.' >&2
fi

# header bytes reaching outside of its bounds
dd if=file.tar bs=599 count=1 iflag=fullblock status=none of=head
echo '123 malcs=1' > body
dd if=file.tar bs=611 skip=1 iflag=fullblock status=none of=tail
cat head body tail > malicious.tar

if ! (
  set -e
  clache.sh -e < malicious.tar 2>&1 > /dev/null | grep '^ERROR: A malicious pax header'
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected a malicious pax header reaching out of bounds to fail.' >&2
  result=1
else
  echo 'PASSED: Fail on pax header reaching out of bounds.' >&2
fi

# fake hash utility
dd if=file.tar bs=592 count=1 iflag=fullblock status=none of=head
echo 'fakers' > body
dd if=file.tar bs=599 skip=1 iflag=fullblock status=none of=tail
cat head body tail > bad-utl.tar

if ! (
  set -e
  clache.sh -e < bad-utl.tar 2>&1 > /dev/null | grep '^ERROR: could not determine checksum algorithm.'
) > /dev/null 2>&1; then
  echo 'Test Failed: Expected bad hash utility to fail.' >&2
  result=1
else
  echo 'PASSED: Fail on bad hash utility.' >&2
fi

exit "$result"
