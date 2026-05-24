#!/bin/bash
# clache v0.6
# Copyright (c) 2026 Sam Gleske https://github.com/samrocketman/clache
# MIT Licensed
# Initially Created Sat May 16 05:58:44 EDT 2026
# Pop!_OS 24.04 LTS
# Linux 6.18.7-76061807-generic x86_64
# GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
# dd (coreutils) 9.4
# xxd 2023-10-25 by Juergen Weigert et al.
# GNU Awk 5.2.1, API 3.2, PMA Avon 8-g1, (GNU MPFR 4.2.1, GNU MP 6.3.0)
# od (GNU coreutils) 9.4
# bc 1.07.1
#
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

# Quickly check for prerequisite utilities
failed_preflight=false
for x in awk bc od dd tar xxd tr; do
  if ! type -P "$x" > /dev/null; then
    echo "Missing dependency '$x'." >&2
    failed_preflight=true
  fi
done
if [ "$failed_preflight" = true ]; then
  exit 1
fi

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
${0##*/} [--nosudo] --create FILE... > tar-to-create.tar

DESCRIPTION
  Create or extract cache using tar.  Provide both relative or full path names
  to create the cache and it will later be restored.

OPTIONS
  --create FILE..., -c FILE...
    Writes archive to stdout.  Creates a cache.  Provided on or more FILE to
    add to the cache.  Can be relative of full paths.

  --extract, -e
    Reads a tar file from stdin.  Extracts the cache.

  --nosudo, -n
    When creating or extracting an archive the full path archive can execute
    tar without sudo.

  -l DIR, --large-dir DIR
    Customize where intermediate tar file can be written.  Sometimes the
    intermediate tar file can be significantly larger than available /tmp file
    space.  Default: /tmp mktemp directory.

  --help, -h
    Show help.
EOF
exit 1
}
bin_to_hex() {
  xxd -p | LC_ALL=C tr -d '\n'
}
sanitize_nonnumeric() {
  LC_ALL=C tr -dc '0-9'
}
sanitize_nonascii() {
  LC_ALL=C tr -dc '[:print:]'
}
sanitize_cntrl() {
  LC_ALL=C tr -d '[:cntrl:]\0'
}
isBlockZeros() {
  [ -z "$(dd bs=512 count=1 status=none | bin_to_hex | tr -d '0')" ]
}
getTarFormat() {
  dd if="$1" bs=1 count=6 skip=257 status=none | sanitize_nonascii
}
verify_tar_chksum() {
  local calculated_checksum tarfile_checksum
  calculated_checksum="$(
    {
      dd if="$1" bs=148 count=1 iflag=fullblock status=none
      echo -n '        '
      dd if="$1" skip=156 bs=1 count=356 iflag=fullblock status=none
    } | od -v -A n -t u1 | xargs | tr ' ' '+' | bc
  )"
  calculated_checksum="$(printf '%o\n' "$calculated_checksum")"
  tarfile_checksum="$(
    dd if="$1" skip=148 bs=1 count=8 status=none | \
      sanitize_nonnumeric | \
      sed 's/^[ 0]*//' | \
      xargs
  )"
  if [ ! "$tarfile_checksum" -eq "$calculated_checksum" ]; then
    echo 'ERROR: Tar header checksum invalid.' >&2
    exit 1
  fi
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
  verify_tar_chksum "$TAR_HEADER"
  tar_format="$(getTarFormat "$TAR_HEADER")"
  if [ ! "${tar_format}" = ustar ]; then
    echo 'ERROR: could not determine supported tar format; only ustar and pax(ustar) supported' >&2
    exit 1
  fi
  typeflag="$(dd if="$TAR_HEADER" bs=1 count=1 skip=156 status=none | sanitize_nonascii | tr -d ' ')"
  if [ "${typeflag}" = x ]; then
    if [ ! "$tar_format" = ustar ]; then
      echo "ERROR: Only pax ustar format is supported.  Found format '${tar_format}'." >&2
      exit 1
    fi
    tar_format='pax'
    mv "$TAR_HEADER" "$PAXTAR_HEADER"
  elif [ -z "${typeflag:-}" ] || [ "${typeflag}" = 0 ]; then
    tar_format=ustar
  elif [ "${typeflag}" = g ]; then
    echo "ERROR: Only pax typeflag 'x' is supported.  Found typeflag 'g'." >&2
    exit 1
  else
    echo "ERROR: Unsupported tar format detected.  Found typeflag '${typeflag}'." >&2
    exit 1
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
  verify_tar_chksum "$TAR_HEADER"
  if [ ! "$(getTarFormat "$TAR_HEADER")" = ustar ]; then
    echo 'ERROR: inner tar is not expected format.' >&2
    exit 1
  fi
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
  dd bs=100 count=1 status=none | sanitize_nonascii
}
fileSize() {
  local file_size pax_size
  file_size="$(ustarSize < "$TAR_HEADER")"
  if [ "$tar_format" = pax ]; then
    pax_size="$(paxField size | sanitize_nonnumeric)"
    if [ -n "${pax_size:-}" ]; then
      # inverted logic to account for malformed expression errors
      if ! [ "$pax_size" -ge 0 ]; then
        echo 'ERROR: Invalid pax header file size has been encountered.' >&2
        exit 1
      fi
      file_size="$pax_size"
    fi
  fi
  echo "$file_size"
}
ustarSize() {
  local size
  size="$(dd bs=1 skip=124 count=12 status=none | sanitize_nonnumeric)"
  # ustar size can be zero or space padded
  size="$( echo "$size" | awk '{gsub("^[ 0]+", "", $0); print; }' )"
  # convert octal to decimal
  printf '%d\n' "0${size}"
}
paxFieldAwkScript() {
cat<<'EOF'
BEGIN {
  cont=0
}
{
  current_line=length($0)+1
}
cont > 0 {
  # complex pax header continued
  cont=cont+current_line
  headers[name]=headers[name]$0"\n"
  if(cont >= size[name]) {
    cont=0
  }
  next
}
{
  record=substr($0, length($1)+2)
  name=record
  gsub(/=.*$/, "", name)
  value=substr(record, length(name)+2)
  headers[name]=value"\n"
  size[name]=$1
  if($1 == current_line) {
    # simple pax header
    next
  }
}
{
  cont=current_line
}
END {
  printf("%s", headers[field])
}
EOF
}
paxField() {
  < "$PAX_HEADER" awk -v field="$1" "$(paxFieldAwkScript)" | sanitize_cntrl
}
dd_max_read() {
  local FILE_SIZE max_bs remainder
  # To reasonably maximize throughput dd will read max_bs of data at a time.
  # 5MB read buffer
  max_bs=5242880
  FILE_SIZE="$1"
  # size to nearest 512-byte block
  FILE_SIZE="$(( ((FILE_SIZE+511)/512)*512 ))"
  remainder="$(( FILE_SIZE%max_bs ))"
  dd bs="$max_bs" count="$(( FILE_SIZE/max_bs ))" iflag=fullblock status=none
  if [ "$remainder" -gt 0 ]; then
    dd bs="$remainder" count=1 iflag=fullblock status=none
  fi
}
readTarFile() {
  local FILE_NAME FILE_SIZE
  readTarHeader
  FILE_NAME="$(fileName)"
  FILE_SIZE="$(fileSize)"
  case "$FILE_NAME" in
    agent-os-cache.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes" >&2
      dd_max_read "$FILE_SIZE" | {
        if [ "$nosudo" = true ]; then
          echo "tar -xC / -f $FILE_NAME" >&2
          tar -xC /
        else
          echo "sudo tar -xC / -f $FILE_NAME" >&2
          sudo tar -xC /
        fi
      }
      ;;
    agent-workspace-cache.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes" >&2
      echo "tar -xf $FILE_NAME" >&2
      dd_max_read "$FILE_SIZE" status=none | tar -x
      ;;
#    *.tar)
#      echo "$FILE_NAME is $FILE_SIZE bytes" >&2
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
  set +o pipefail
  tar --format pax -c "$1" 2>/dev/null | {
    dd bs=512 count=1 status=none > "$TMP_DIR/prefix_header"
    header_size="$(ustarSize < "$TMP_DIR/prefix_header")"
    header_blocks="$(( (header_size + 511 ) / 512))"
    dd bs=512 count="$header_blocks" status=none > "$TMP_DIR/prefix_header_body"
    dd bs=512 count=1 status=none > "$TMP_DIR/prefix_header_file"
    # create tar prefix
    cat "$TMP_DIR/prefix_header" "$TMP_DIR/prefix_header_body" "$TMP_DIR/prefix_header_file"
  }
)
canonical_path() (
  cd "$1"
  echo "${PWD%/}"
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
largetar_dir="${TMP_DIR}"
export largetar_dir nosudo
while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      echo 'ERROR: the "--" option is not supported.' >&2
      exit 1
      ;;
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
    -l|--large-dir)
      shift
      largetar_dir="${1:-}"
      if [ ! -d "${largetar_dir:-}" ]; then
        echo "ERROR: --large-dir '${largetar_dir:-}' expected to be a directory." >&2
        exit 1
      fi
      largetar_dir="$(canonical_path "${largetar_dir}")"
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
  if [ -n "${full_paths:-}" ]; then
    (
      cd /
      if [ "$nosudo" = true ]; then
        echo "tar --format pax -cC / ${full_paths[*]}" >&2
        tar --format pax -c -- \
          "${full_paths[@]}" > "${largetar_dir}/agent-os-cache.tar"
      else
        echo "sudo tar --format pax -cC / ${full_paths[*]}" >&2
        # I want the tar to be sudo and write to current nonsudo user so
        # disable shellcheck warning.
        # shellcheck disable=SC2024
        sudo tar --format pax -c -- \
          "${full_paths[@]}" > "${largetar_dir}/agent-os-cache.tar"
      fi
      cd "${largetar_dir}"
      # same as `tar --format pax -c agent-os-cache.tar` except it does not
      # write the end or archive marker.
      outer_tar_prefix agent-os-cache.tar > "$TMP_DIR"/agent-os-cache-prefix
      cat "$TMP_DIR"/agent-os-cache-prefix agent-os-cache.tar
      rm -f agent-os-cache.tar
    )
  fi
  if [ -n "${relative_paths:-}" ]; then
    (
      echo "tar --format pax -c ${relative_paths[*]}" >&2
      tar --format pax -c -- \
        "${relative_paths[@]}" > "${largetar_dir}/agent-workspace-cache.tar"
      cd "${largetar_dir}"
      tar --format pax -c agent-workspace-cache.tar
      rm -f agent-workspace-cache.tar
    )
  else
    # no agent-workspace-cache.tar so we need to write out the "end of archive"
    # marker bytes manually (two 512-byte blocks of all zeros)
    dd if=/dev/zero bs=1024 count=1 status=none
  fi
fi
