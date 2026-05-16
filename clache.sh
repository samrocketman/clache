#!/bin/bash
# Craeted by Sam Gleske
# Sat May 16 05:58:44 EDT 2026
# DESCRIPTION
#   This script is intended for CI systems to be able to create and extract a
#   cache using streams.  Use case would be a cloud object store downloading a
#   file and streaming the download into this script.  This script then handles
#   all extraction via stdin without writing intermediate tar files to disk.
#
#   During file creation intermediate files must be written to disk.  This is
#   necessary due to tar requiring the inner tar file size in order to create
#   the outer tar.
#
#   Create cache strategy: Files and folders that will be added to the cache
#   will be broken up into two tar commands.
#
#     1. sudo tar (sudo can be opt-out) from the system root when full paths
#        are given.
#     2. non-sudo tar for file paths relative to the current working directory.
#
#   Extraction happens in the same two phases:
#
#     1. `sudo tar -xC /` for full path names.
#     2. `tar -x` for relative path names.
#
#   If you create the outer and inner tar files without this script, then tar
#   files should always be created with one of the following commands.
#     tar --format ustar -c ...
#     tar --format pax -c ...
#
#   Only ustar and pax(ustar) file formats supported.
#   https://pubs.opengroup.org/onlinepubs/009695399/utilities/pax.html
#
set -euo pipefail
export tar_format TAR_HEADER PAX_HEADER TMP_DIR INNER_PAX_TAR
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
PAXTAR_HEADER="$TMP_DIR/outer_tar"
TAR_HEADER="$TMP_DIR/inner_tar"
PAX_HEADER="$TMP_DIR/pax_header"

bin_to_hex() {
  xxd -p | tr -d '\n'
}
isBlockZeros() {
  [ "$(dd bs=512 count=1 status=none | bin_to_hex | sed 's/0*/0/')" = 0 ]
}
initializeFileMode() {
  local typeflag format
  dd bs=512 count=1 status=none > "$TAR_HEADER"
  if isBlockZeros < "$TAR_HEADER"; then
    if ! { dd bs=512 count=1 status=none | isBlockZeros; }; then
      echo 'ERROR: archive is likely corrupt.  End of archive not determined.' >&2
      exit 1
    fi
    # tar file finish
    exit 0
  fi
  tar_format="$(dd if="$TAR_HEADER" bs=1 count=6 skip=257 status=none | tr -d '\0')"
  if [ "$(dd if="$TAR_HEADER" bs=10 count=1 status=none)" = 'PaxHeader/' ]; then
    if [ ! "$tar_format" = ustar ]; then
      echo "ERROR: Only pax ustar format is supported.  Found format '${tar_format}'."
      exit 1
    fi
    typeflag="$(dd if="$TAR_HEADER" bs=1 count=1 skip=156 status=none)"
    if [ ! "${typeflag}" = x ]; then
      echo "ERROR: Only pax typeflag 'x' is supported.  Found typeflag '${typeflag}'." >&2
      exit 1
    fi
    tar_format=pax
    mv "$TAR_HEADER" "$PAXTAR_HEADER"
  else
    tar_format=ustar
  fi
}
readTarHeader() {
  initializeFileMode
  if [ "$tar_format" = ustar ]; then
    return
  fi
  local header_size header_blocks
  header_size="$(ustarSize < "$PAXTAR_HEADER")"
  # equalent to Math.ceil for upper 512 byte block size
  header_blocks="$(( (header_size + 511 ) / 512))"
  # read from stdin in 512 byte blocks but only write real header size to disk
  if [ "$header_blocks" = 0 ]; then
    echo > "$PAX_HEADER"
  else
    dd bs=512 count="$header_blocks" status=none | \
      dd bs=1 count="$header_size" status=none > "$PAX_HEADER"
  fi
  dd bs=512 count=1 status=none > "$TAR_HEADER"
}
fileName() {
  local name pax_path
  name="$(ustarName < "$TAR_HEADER")"
  if [ "$tar_format" = pax ]; then
    pax_path="$(paxField path)"
    if [ -n "${pax_path:-}" ]; then
      name="$pax_path"
    else
      name="${name#PaxHeader/}"
    fi
  fi
  echo "$name"
}
ustarName() {
  dd bs=100 count=1 status=none | xargs
}
fileSize() {
  local file_size pax_size
  file_size="$(ustarSize < "$TAR_HEADER")"
  if [ "$tar_format" = pax ]; then
    pax_size="$(paxField size)"
    if [ -n "${pax_size:-}" ]; then
      file_size="$pax_size"
    fi
  fi
  echo "$file_size"
}
ustarSize() {
  printf "%d\n" "$(dd bs=1 skip=124 count=12 status=none | xxd | awk '{print $NF}')"
}
paxField() {
  awk '$2 ~ /^'"$1"'=/ { gsub(/[^=]*=/, "", $0); print }' < "$PAX_HEADER"
}

readTarFile() {
  readTarHeader
  FILE_NAME="$(fileName)"
  # size to nearest 512-byte block
  FILE_SIZE="$(fileSize)"
  # TODO: do different things depending on files encountered.
  case "$FILE_NAME" in
     *.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes"
      echo -n 'Number of tar entries: '
      dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none | tar -t | wc -l
      ;;
    *)
      # skip processing
      echo "Skipping $FILE_NAME; seeking $FILE_SIZE bytes"
      dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none of=/dev/null
      ;;
  esac
}

# iterate all files
while readTarFile; do
  true
done
