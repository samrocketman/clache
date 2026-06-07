#!/bin/bash
set -euo pipefail
declare -a files
if [ ! -f ~/10gb ]; then
  # write 10gb file
  (
    set -x
    dd if=/dev/zero of=~/10gb bs=16M count=640 iflag=fullblock oflag=dsync status=progress
  )
fi
case "${1:-}" in
  big)
    files=( ~/10gb README.md )
    ;;
  small)
    files=( ~/.m2/repository README.md )
    ;;
  *)
    echo 'choose big or small' >&2
    exit 1
    ;;
esac
benchmark() (
  set -euo pipefail
  time ./clache.sh "$@" -c -n "${files[@]}" > file.tar
  ./clache.sh -e -n < file.tar
  time ./clache.sh -e -n < file.tar
)
for y in 0 1 2; do
  echo '================================================================================'
  echo "repeat ${y}; raw benchmark"
  echo '================================================================================'
  benchmark
done
for x in 1 2 3; do
  for y in 0 1 2; do
    echo '================================================================================'
    echo "repeat ${y}; -H${x} benchmark"
    echo '================================================================================'
    benchmark -H "$x"
  done
done
for x in 1 256; do
  for y in 0 1 2; do
    echo '================================================================================'
    echo "repeat ${y}; -a ${x} benchmark"
    echo '================================================================================'
    benchmark -a "$x"
  done
done
say_job_done.sh "benchmarks completed"
