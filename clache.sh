#!/bin/bash
# Created by Sam Gleske
# Sat May 16 05:58:44 EDT 2026
# Pop!_OS 24.04 LTS
# Linux 6.18.7-76061807-generic x86_64
# GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
# dd (coreutils) 9.4
# xxd 2023-10-25 by Juergen Weigert et al.
# GNU Awk 5.2.1, API 3.2, PMA Avon 8-g1, (GNU MPFR 4.2.1, GNU MP 6.3.0)
# DESCRIPTION
#   This script is intended for CI systems to be able to create and extract a
#   cache using streams.  Use case would be a cloud object store downloading a
#   file and streaming the download into this script.  This script then handles
#   all extraction via stdin without writing large tar files to disk.
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
# CREATING TARS WITHOUT THIS SCRIPT
#
#   If you create the outer and inner tar files without this script, then tar
#   files should always be created with one of the following commands.
#     tar --format ustar -c ...
#     tar --format pax -c ...
#
#   Expected tar layout:
#
#     your-cache.tar
#       |- agent-os-cache.tar - the sudo-created tar file.
#       |- agent-workspace-cache.tar - working directory tar file.
#
# PERFORMANCE FYI
#
#   Compression is intentionally omitted.  If you want compression then you
#   should process it via stdin/stdout.
#
#   During file creation large tar files must be written to disk.  This is
#   necessary due to tar requiring the inner tar file size in order to create
#   the outer tar.
#
#   During file extraction only a few KB of tar data is written to temporary
#   space.  This is used for seeking and passing data from stdin of this script
#   to stdin of multiple tar commands depending on the inner tar file name.
#
#   Cache creation is expected to take longer than cache extraction.
#
#   Some benchmarks for stdin processing:
#     - ~10GB processed in 15s by this script.
#     - ~200MB processed in 0.6s.
#
# TAR SUPPORT
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
#
# FUNCTIONS (see main at the end)
#
helptext() {
cat >&2 <<EOF
${0##*/} [--nosudo] --extract < tar-to-extract.tar
${0##*/} [--nosudo] --create -- FILE... > tar-to-create.tar

DESCRIPTION
  Create or extract cache using tar.  Provide both relative or full path names
  to create the cache and it will later be restored.

OPTIONS
  --create -- FILE..., -c -- FILE...
    Writes archive to stdout.  Creates a cache.  Provided on or more FILE to
    add to the cache.  Can be relative of full paths.

  --extract, -e
    Reads a tar file from stdin.  Extracts the cache.

  --nosudo, -n
    When creating or extracting an archive the full path archive can execute
    tar without sudo.

  --help, -h
    Show help.
EOF
exit 1
}
bin_to_hex() {
  xxd -p | tr -d '\n'
}
isBlockZeros() {
  [ "$(dd bs=512 count=1 status=none | bin_to_hex | sed 's/0*/0/')" = 0 ]
}
determineTarFormat() {
  local typeflag
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
  if {
    dd if="$TAR_HEADER" bs=100 count=1 status=none | \
    grep -i PaxHeader > /dev/null
  }; then
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
  determineTarFormat
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
  dd bs=100 count=1 status=none | tr -d '\0' | xargs
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
  local size
  size="$(dd bs=1 skip=124 count=12 status=none | tr -d '\0')"
  # convert octal to decimal
  echo "$((8#$size))"
}
paxField() {
  awk '$2 ~ /^'"$1"'=/ { gsub(/[^=]*=/, "", $0); print }' < "$PAX_HEADER"
}
readTarFile() {
  readTarHeader
  FILE_NAME="$(fileName)"
  # size to nearest 512-byte block
  FILE_SIZE="$(fileSize)"
  case "$FILE_NAME" in
    agent-os-cache.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes"
      if [ "$nosudo" = true ]; then
        echo "tar -xC / -f $FILE_NAME" >&2
        dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none | tar -xC /
      else
        echo "sudo tar -xC / -f $FILE_NAME" >&2
        dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none | sudo tar -xC /
      fi
      ;;
    agent-workspace-cache.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes"
      echo "tar -xf $FILE_NAME" >&2
      dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none | tar -x
      ;;
#    *.tar)
#      echo "$FILE_NAME is $FILE_SIZE bytes"
#      echo -n 'Number of tar entries: '
#      dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none | tar -t | wc -l
#      ;;
    *)
      # skip processing
      echo "Skipping $FILE_NAME; seeking $FILE_SIZE bytes" >&2
      dd bs=512 count="$((( FILE_SIZE+511 )/512))" status=none of=/dev/null
      ;;
  esac
}
extract() {
  # iterate all files
  while readTarFile; do
    true
  done
}
outer_tar_prefix() (
  # The purpose of this function is to create a subshell which is equivalent to
  # running `tar --format pax -c file.tar` which creates an outer tar header
  # but only outputting the header without the rest of the tar file.
  # This enables writing out a tar file to stdout in intermediate parts rather
  # than requiring double the space for creating the cache.
  tar --format pax -c "$1" | {
    dd bs=512 count=1 status=none > "$TMP_DIR/prefix_header"
    header_size="$(ustarSize < "$TMP_DIR/prefix_header")"
    header_blocks="$(( (header_size + 511 ) / 512))"
    dd bs=512 count="$header_blocks" status=none > "$TMP_DIR/prefix_header_body"
    dd bs=512 count=1 status=none > "$TMP_DIR/prefix_header_file"
    # create tar prefix
    cat "$TMP_DIR/prefix_header" "$TMP_DIR/prefix_header_body" "$TMP_DIR/prefix_header_file"
  }
)
#
# MAIN
#
if [ "$#" -lt 1 ]; then
  helptext
fi
mode="extract"
full_paths=()
relative_paths=()
nosudo=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      helptext
      ;;
    -c|--create)
      mode=create
      shift
      ;;
    -e|--extract)
      mode=extract
      shift
      ;;
    -n|--nosudo)
      nosudo=true
      shift
      ;;
    /*)
      full_paths+=( "${1#/}" )
      shift
      ;;
    *)
      relative_paths+=( "$1" )
      shift
      ;;
  esac
done

if [ "$mode" = extract ]; then
  extract
else
  # create
  tar_files=()
  if [ -n "${full_paths:-}" ]; then
    (
      cd /
      if [ "$nosudo" = true ]; then
        echo "tar -c ${full_paths[*]}" >&2
        tar --format pax --ignore-failed-read -c  -- \
          "${full_paths[@]}" > "${TMP_DIR}/agent-os-cache.tar"
      else
        echo "sudo tar -c ${full_paths[*]}" >&2
        sudo tar --format pax --ignore-failed-read -c  -- \
          "${full_paths[@]}" > "${TMP_DIR}/agent-os-cache.tar"
      fi
      cd "${TMP_DIR}"
      outer_tar_prefix agent-os-cache.tar > agent-os-cache-prefix
      # same as `tar --format pax -c agent-os-cache.tar` except it does not
      # write the end or archive marker.
      cat agent-os-cache-prefix agent-os-cache.tar
      rm agent-os-cache.tar
    )
  fi
  if [ -n "${relative_paths:-}" ]; then
    (
      echo tar -c "${relative_paths[@]}" >&2
      tar --format pax --ignore-failed-read -c -- \
        "${relative_paths[@]}" > "${TMP_DIR}/agent-workspace-cache.tar"
      cd "${TMP_DIR}"
      tar --format pax -c agent-workspace-cache.tar
    )
  else
    # no agent-workspace-cache.tar so we need to write out the "end of archive"
    # marker bytes manually (two 512-byte blocks of all zeros)
    dd if=/dev/zero bs=1024 count=1
  fi
fi
