#!/bin/bash
# clache v0.15
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
#       |- os-cache.tar - the sudo-created tar file.
#       |- pwd-cache.tar - working directory tar file.
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

set -euo pipefail
export tar_format TAR_HEADER PAX_HEADER PAX_GLOBAL_HEADER TMP_DIR
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# clear internally used vars and other security vars
export skip trim file_size_digits_limit
skip=""
trim=""
# an unpractical cache file size limit of 13 digits is ~10TB
file_size_digits_limit=13

#
# FUNCTIONS (see main at the end)
#
preflight_checks() {
  local failed_preflight
  # Quickly check for prerequisite utilities
  failed_preflight=false
  # xxhsum is an optional dependency which falls back to shasum
  # printf is a shell built-in.
  for x in awk bc cat date dd grep head mkfifo mktemp mv od sed shasum stat tar tee tr wc xxd; do
    if ! type -P "$x" > /dev/null; then
      if [ "$x" = shasum ] && (type -P sha256sum && type -P sha1sum; ) > /dev/null; then
        continue
      fi
      echo "Missing dependency '$x'." >&2
      failed_preflight=true
    fi
  done
  # utility compatibility checks
  if [ ! "$(echo x | tr -dc '[:print:]' | wc -c | xargs)" -eq 1 ]; then
    echo 'ERROR: tr does not appear to be compiled with character classes i.e. "[:print:]".' >&2
    echo '       Recommendation: install coreutils.' >&2
    failed_preflight=true
  fi
  if [ ! "$(tar --format pax -cC /dev null 2> /dev/null | getTarTypeflag)" = x ]; then
    echo 'ERROR: tar does not appear to support "--format pax".' >&2
    echo '       Recommendation: install GNU tar.' >&2
    failed_preflight=true
  fi
  if [ "$failed_preflight" = true ]; then
    exit 1
  fi
}
dd() {
  command dd iflag=fullblock status=none "$@"
}
shasum() {
  local alg
  if type -P shasum > /dev/null; then
    command shasum "$@"
  else
    shift
    alg="$1"
    shift
    sha"$alg"sum "$@"
  fi
}
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

  -s, --verify-checksum
    Enforce checksum verification.
    Protects cache against corruption. Header and archive data checksums are
    calculated and verified.  This option works for creation or extraction.

  -a SIZE, --sha SIZE
    Choose the shasum SIZE (1 or 256) to use for archive integrity.
    Default: 1 (only if xxhsum not available)

  -H SIZE, --xxh SIZE
    Choose the xxh SIZE (1, 2, or 3 supported) to use for archive integrity.
    Default: 1

  --no-detect
    If an archive was created with --verify-checksum, this disables the
    autodetection which skips the integrity checks for archives that would
    normally verify checksums.

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
sanitize_nonoctal() {
  LC_ALL=C tr -dc '0-7'
}
sanitize_nonascii() {
  LC_ALL=C tr -dc '[:print:]'
}
sanitize_cntrl() {
  LC_ALL=C tr -d '[:cntrl:]\0' | \
  LC_ALL=C sed -E $'s/\xc2[\x80-\x9f]|\xe2\x80[\x8b-\x8f\xa8-\xae]|\xe2\x81[\xa6-\xa9]|\xef\xbb\xbf//g'
}
isBlockZeros() {
  local block
  block="$(dd bs=512 count=1 | bin_to_hex)"
  if [ ! "${#block}" = 1024 ]; then
    echo 'ERROR: End of tar check could not read a full 512-byte block.' >&2
    exit 1
  fi
  grep -E '^0+$' <<< "$block" > /dev/null
}
dd_optional_stream() {
  local args=()
  while [ "$#" -gt 1 ]; do args+=( "$1" ); shift; done
  if [ -f "${1:-}" ]; then args+=( if="$1" ); else args+=( "$1" ); fi
  dd "${args[@]}"
}
getTarFormat() {
  dd_optional_stream bs=1 count=6 skip=257 "$@" | sanitize_nonascii
}
getTarTypeflag() {
  dd_optional_stream bs=1 count=1 skip=156 "$@" | sanitize_nonascii | tr -d ' '
}
create_tar_header_chksum() {
  local calculated_checksum
  calculated_checksum="$(
    {
      dd if="$1" bs=148 count=1
      echo -n '        '
      dd if="$1" skip=156 bs=1 count=356
    } | od -v -A n -t u1 | xargs | tr ' ' '+' | bc
  )"
  printf '%08o' "$calculated_checksum"
}
verify_tar_chksum() {
  local calculated_checksum tarfile_checksum
  calculated_checksum="$(create_tar_header_chksum "$1" | sed 's/^0*//')"
  tarfile_checksum="$(
    dd if="$1" skip=148 bs=1 count=8 | \
      sanitize_nonoctal | \
      sed 's/^[ 0]*//' | \
      xargs
  )"
  # Inverted to account for arithmetic failures
  if ! {
    [ "$tarfile_checksum" -eq "$calculated_checksum" ] &&
    [ "$tarfile_checksum" -gt 0 ] &&
    [ "$calculated_checksum" -gt 0 ]
  } 2> /dev/null; then
    echo 'ERROR: Tar header checksum invalid.' >&2
    exit 1
  fi
}
# Tee stdin through a fifo for concurrent checksum create or verify.
#   create FILE       write stream to FILE; checksum -> $TMP_DIR/tar-checksum
#   verify-file FILE  checksum -c file contents; output -> checksum-output
#   verify-stream     tee stream to stdout; checksum -c -> checksum-output
stream_checksum() {
  local mode="$1"
  shift
  local fifo="$TMP_DIR/checksum.fifo"
  local sumpid
  mkfifo "$fifo"
  case "$mode" in
    create)
      checksum_data - < "$fifo" > "$TMP_DIR/tar-checksum" &
      sumpid=$!
      tee "$fifo" > "$1"
      ;;
    verify-file)
      (
        checksum_data -c "$TMP_DIR/checksum"
        echo $? > "$TMP_DIR/checksum-status"
      ) < "$fifo" > "$TMP_DIR/checksum-output" &
      sumpid=$!
      cat "$1" > "$fifo"
      ;;
    verify-stream)
      (
        checksum_data -c "$TMP_DIR/checksum"
        echo $? > "$TMP_DIR/checksum-status"
      ) < "$fifo" > "$TMP_DIR/checksum-output" &
      sumpid=$!
      tee "$fifo"
      ;;
    *)
      echo "ERROR: unknown stream_checksum mode '${mode}'." >&2
      rm -f "$fifo"
      exit 1
      ;;
  esac
  wait "$sumpid"
  rm -f "$fifo"
  if [ "$mode" = verify-file ]; then
    cat "$TMP_DIR/checksum-output"
  fi
}
algorithm_supported() {
  case "${1:-}" in
    shasum) case "${2:-}" in 1|256) true;; *) false ;; esac ;;
    xxhsum) case "${2:-}" in 1|2|3) true;; *) false ;; esac ;;
    *) false ;;
  esac
}
determineTarFormat() {
  local typeflag
  dd bs=512 count=1 > "$TAR_HEADER"
  if isBlockZeros < "$TAR_HEADER"; then
    if ! { dd bs=512 count=1 | isBlockZeros; }; then
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
  typeflag="$(getTarTypeflag "$TAR_HEADER")"
  if [ "${typeflag}" = g ]; then
    local header_size
    if [ "${disable_integrity_detection}" = false ]; then
      enforce_integrity=true
    fi
    header_size="$(ustarSize < "$TAR_HEADER")"
    if [ "$header_size" -gt 5242880 ]; then
      echo 'ERROR: aborted because global pax header size is greater than 5MB.' >&2
      exit 1
    elif [ "$header_size" -lt 1 ]; then
      echo 'ERROR: aborted because global pax header size is less than 1 byte.' >&2
      exit 1
    fi
    dd_max_read "$header_size" | trim=1 dd_max_read "$header_size" > "$PAX_GLOBAL_HEADER"
    local cl_utl cl_alg
    cl_utl="$(get_pax_field "$PAX_GLOBAL_HEADER" cl_utl)"
    cl_alg="$(get_pax_field "$PAX_GLOBAL_HEADER" cl_alg)"
    if ! algorithm_supported "${cl_utl:-}" "${cl_alg:-}"; then
      echo 'ERROR: could not determine checksum algorithm.' >&2
      exit 1
    else
      sum_util="${cl_utl}"
      if [ "${sum_util}" = shasum ]; then
        sha_size="${cl_alg}"
      elif [ "${sum_util}" = xxhsum ]; then
        xxh_size="${cl_alg}"
      fi
    fi

    # continue on with pax detection and re-initialze values
    dd bs=512 count=1 > "$TAR_HEADER"
    tar_format="$(getTarFormat "$TAR_HEADER")"
    if [ ! "${tar_format}" = ustar ]; then
      echo 'ERROR: could not determine supported tar format; only ustar and pax(ustar) supported' >&2
      exit 1
    fi
    verify_tar_chksum "$TAR_HEADER"
    typeflag="$(getTarTypeflag "$TAR_HEADER")"
  fi
  if [ "${typeflag}" = x ]; then
    if [ ! "$tar_format" = ustar ]; then
      echo "ERROR: Only pax ustar format is supported.  Found format '${tar_format}'." >&2
      exit 1
    fi
    tar_format='pax'
    mv "$TAR_HEADER" "$PAXTAR_HEADER"
  elif {
    [ -z "${typeflag:-}" ] || [ -n "$(sanitize_nonoctal <<< "$typeflag")" ]
  }; then
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
  local checksum
  determineTarFormat
  if [ "$tar_format" = ustar ]; then
    return
  fi
  local header_size
  header_size="$(ustarSize < "$PAXTAR_HEADER")"
  # 5MB header size limit
  if [ "$header_size" -gt 5242880 ]; then
    echo 'ERROR: aborted because pax header size is greater than 5MB.' >&2
    exit 1
  fi
  # Read 512-byte blocks from stdin and trim the data before writing to disk.
  if [ "$header_size" -eq 0 ]; then
    echo > "$PAX_HEADER"
  else
    dd_max_read "$header_size" | trim=1 dd_max_read "$header_size" > "$PAX_HEADER"
  fi
  dd bs=512 count=1 > "$TAR_HEADER"
  verify_tar_chksum "$TAR_HEADER"
  if [ ! "$(getTarFormat "$TAR_HEADER")" = ustar ]; then
    echo 'ERROR: inner tar is not expected format.' >&2
    exit 1
  fi
  local typeflag
  typeflag="$(getTarTypeflag "$TAR_HEADER")"
  if ! {
    [ -z "${typeflag:-}" ] || [ "${typeflag}" = 0 ]
  }; then
    echo 'ERROR: unexpected inner tar typeflag detected.' >&2
    exit 1
  fi
  if [ "${enforce_integrity}" = true ]; then
    checksum="$(get_pax_field "$PAX_GLOBAL_HEADER" pax_chk)"
    if [ -z "${checksum:-}" ]; then
      echo 'ERROR: cache integrity is enabled but no pax header checksum available.' >&2
      exit 1
    fi
    echo "${checksum}" > "${TMP_DIR}/checksum"
    echo "header checksum$(stream_checksum verify-file "$PAX_HEADER")"
    if [ ! "$(<"$TMP_DIR/checksum-status")" = 0 ]; then
      exit 1
    fi
  fi
}
fileName() {
  local name pax_path
  name="$(ustarName < "$TAR_HEADER")"
  if [ "$tar_format" = pax ]; then
    pax_path="$(paxField path)"
    if [ -n "${pax_path:-}" ]; then
      name="$pax_path"
    fi
  fi
  echo "$name"
}
ustarName() {
  local name prefix
  name="$(dd bs=100 count=1 | sanitize_nonascii)"
  dd bs=245 skip=1 count=0
  prefix="$(dd bs=155 count=1 | sanitize_nonascii)"
  if [ -n "${prefix:-}" ]; then
    echo "${prefix}/${name:-}"
  else
    echo "${name:-}"
  fi
}
fileSize() {
  local file_size pax_size
  file_size="$(ustarSize < "$TAR_HEADER")"
  if [ "$tar_format" = pax ]; then
    pax_size="$(paxField size)"
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
  size="$(dd bs=1 skip=124 count=12 | sanitize_nonoctal)"
  # ustar size can be zero or space padded
  size="$( echo "$size" | awk '{gsub("^[ 0]+", "", $0); print; }' )"
  # convert octal to decimal
  printf '%d\n' "0${size}"
}
stat_file_size() {
  local stat_cmd
  case "$(uname -s)" in
    Darwin|*BSD) stat_cmd=(stat -f %z) ;;
    *) stat_cmd=(stat -c %s) ;;
  esac
  "${stat_cmd[@]}" "$1"
}
get_pax_field() {
  if [ ! -f "$1" ]; then
    return
  fi
  local max_bs skip_bytes previously_skipped record_header record_name
  local record_size header_size pax_record_limit pax_records
  max_bs="$(stat_file_size "$1")"
  skip_bytes=0
  previously_skipped=-1
  pax_record_limit=50
  pax_records=0
  until [ "$skip_bytes" -eq "$previously_skipped" ]; do
    if [ "$pax_records" -gt "$pax_record_limit" ]; then
      echo "ERROR: encountered more pax records than allowed (limit ${pax_record_limit})." >&2
      exit 1
    fi
    record_header="$(
      set +o pipefail
      skip="$skip_bytes" trim=1 dd_max_read 1024 < "$1" | \
      awk '{gsub(/=.*$/, "", $0);print;exit}'
    )"
    if [ -z "${record_header:-}" ]; then
      break
    fi
    pax_records="$((pax_records+1))"
    if ! LC_ALL=C grep -E '^[0-9]+ [-._a-zA-Z0-9]+$' <<< "$record_header" > /dev/null; then
      echo 'ERROR: A malformed pax record was encountered.' >&2
      exit 1
    fi
    record_name="${record_header#* }"
    record_size="$(sanitize_nonnumeric <<< "${record_header% *}")"
    if [ ! "$record_size" = "$(awk '{print $1}' <<< "${record_header}")" ]; then
      echo 'ERROR: invalid characters detected in pax size.' >&2
      exit 1
    fi
    # newline included in size intentional (because record should exclude =)
    header_size="$(printf '%s\n' "${record_header}" | LC_ALL=C wc -c)"
    if ! {
      [ "${#record_size}" -le "$file_size_digits_limit" ] &&
      [ "$record_size" -le "$max_bs" ] &&
      [ "$record_size" -ge "$((header_size+1))" ] &&
      # minimum pax record is `5 a=\n` which is just key "a" with empty value.
      [ "$record_size" -ge 5 ] &&
      [ "$((skip_bytes+record_size))" -le "$max_bs" ]
    } 2> /dev/null; then
      echo 'ERROR: A malicious pax header record attempted to reach outside of the pax header.' >&2
      exit 1
    fi
    if [ "$record_name" = "$2" ]; then
      # Retrieve the value of the matching pax header record.
      skip="$skip_bytes" trim=1 dd_max_read "$((skip_bytes+record_size))" < "$1" | \
        skip="$header_size" trim=1 dd_max_read "$record_size"
      break
    fi
    previously_skipped="$skip_bytes"
    skip_bytes="$((skip_bytes + record_size))"
    if [ "$skip_bytes" -ge "$max_bs" ]; then
      break
    fi
  done
}
paxField() {
  if [ "$1" = size ]; then
    local pax_size
    pax_size="$(get_pax_field "$PAX_HEADER" "$1" | sanitize_nonnumeric | sed -E 's/^0+//')"
    if [ "${#pax_size}" -gt "$file_size_digits_limit" ]; then
      echo 'ERROR: pax size header returned greater than 10 terabytes.' >&2
      exit 1
    fi
    echo "${pax_size:-}"
  else
    get_pax_field "$PAX_HEADER" "$1" | sanitize_cntrl
  fi
}
dd_max_read() {
  # skip and trim env vars are intended to be optionally passed by prefix.
  # e.g. skip="bs to skip" trim=1 dd_max_read "max_bs to read"
  # trim - 1: will read exact bytes; not defined reads nearest 512-byte block.
  # skip - skip bs before reading up to max_bs (do not read beyond max_bs)
  local FILE_SIZE max_bs seek
  # To reasonably maximize throughput dd will read max_bs of data at a time.
  # 5MB read buffer
  max_bs=5242880
  FILE_SIZE="${1:-0}"
  seek="${skip:-0}"
  if [ -z "${trim:-}" ]; then
    # size to nearest 512-byte block
    FILE_SIZE="$(( ((FILE_SIZE+511)/512)*512 ))"
    seek="$(( ((seek+511)/512)*512 ))"
  fi
  if [ "${seek}" -gt 0 ]; then
    # negative file sizes get ignored later with a -gt 0 check
    FILE_SIZE="$((FILE_SIZE-seek))"
  fi
  if [ "${seek}" -gt "$max_bs" ]; then
    dd bs="$max_bs" skip="$(( seek/max_bs ))" count=0
    seek="$(( seek%max_bs ))"
  fi
  if [ "${seek}" -gt 0 ]; then
    dd bs="$seek" skip=1 count=0
  fi
  if [ "${FILE_SIZE}" -gt "$max_bs" ]; then
    dd bs="$max_bs" count="$(( FILE_SIZE/max_bs ))"
    FILE_SIZE="$(( FILE_SIZE%max_bs ))"
  fi
  if [ "${FILE_SIZE}" -gt 0 ]; then
    dd bs="$FILE_SIZE" count=1
  fi
}
extract_or_enforce_checksum() {
  if [ "${enforce_integrity}" = true ]; then
    checksum="$(get_pax_field "$PAX_GLOBAL_HEADER" fil_chk)"
    if [ -z "${checksum:-}" ]; then
      echo 'ERROR: cache integrity is enabled but no archive checksum available.' >&2
      exit 1
    fi
    echo "${checksum}" > "$TMP_DIR/checksum"
    stream_checksum verify-stream | "$@"
    echo "${FILE_NAME:-archive} checksum$(<"$TMP_DIR/checksum-output")" >&2
    if [ ! "$(<"$TMP_DIR/checksum-status")" = 0 ]; then
      exit 1
    fi
  else
    "$@"
  fi
}
readTarFile() {
  local FILE_NAME FILE_SIZE
  readTarHeader
  FILE_NAME="$(fileName)"
  FILE_SIZE="$(fileSize)"
  case "$FILE_NAME" in
    os-cache.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes" >&2
      dd_max_read "$FILE_SIZE" | {
        if [ "$nosudo" = true ]; then
          echo "tar -xC / -f $FILE_NAME" >&2
          extract_or_enforce_checksum tar -xC /
        else
          echo "sudo tar -xC / -f $FILE_NAME" >&2
          extract_or_enforce_checksum sudo tar -xC /
        fi
      }
      ;;
    pwd-cache.tar)
      echo "$FILE_NAME is $FILE_SIZE bytes" >&2
      echo "tar -xf $FILE_NAME" >&2
      dd_max_read "$FILE_SIZE" | extract_or_enforce_checksum tar -x
      ;;
    *)
      echo 'ERROR: an unknown file was encountered in the cache archive.' >&2
      exit 1
      ;;
  esac
}
extract() {
  # there's only two inner archive files in a clache archive.
  readTarFile
  readTarFile
  # trigger end of archive logic
  readTarFile
  echo 'ERROR: The archive has more data than expected.' >&2
  exit 1
}
checksum_data() {
  case "$sum_util" in
    xxhsum)
      if [ "${1:-}" = '-c' ]; then
        xxhsum -H"$xxh_size" "$@" | sed 's/stdin/-/'
      else
        xxhsum -H"$xxh_size" "$@"
      fi
      ;;
    shasum)
      shasum -a "$sha_size" "$@"
      ;;
    *)
      echo 'ERROR: unknown checksum data detected.' >&2
      exit 1
      ;;
  esac
}
create_pax_headers() {
  local bs header
  for x in "$@"; do
    bs="$((${#x}+1))"
    bs="$((${#bs}+1+bs))"
    header="$bs $x"
    if [ "$bs" -lt "$((${#header}+1))" ]; then
      bs="$((bs+1))"
      header="$bs $x"
    fi
    echo "$header"
  done
}
pax_global_integrity_header() {
  local cl_utl cl_alg
  cl_utl="$sum_util"
  if [ "$cl_utl" = shasum ]; then
    cl_alg="$sha_size"
  elif [ "$cl_utl" = xxhsum ]; then
    cl_alg="$xxh_size"
  fi
  create_pax_headers "pax_chk=${1}" "fil_chk=${2}" "cl_utl=${cl_utl}" "cl_alg=${cl_alg}" > "$TMP_DIR/tmp_pax_headers"
  local header_bs
  header_bs="$(stat_file_size "$TMP_DIR/tmp_pax_headers")"
  {
    # name (100 bs)
    echo -n 'pax_global_integrity_header'
    dd if=/dev/zero bs=73 count=1
    # mode (8 bs)
    echo -n '0000666'
    dd if=/dev/zero bs=1 count=1
    # uid (8 bs)
    echo -n '0000000'
    dd if=/dev/zero bs=1 count=1
    # gid (8 bs)
    echo -n '0000000'
    dd if=/dev/zero bs=1 count=1
    # size (octal 12 bs; last b is nul)
    printf '%011o' "$header_bs"
    dd if=/dev/zero bs=1 count=1
    # mtime (12 bs)
    printf '%o' "$(date +%s)" | head -c11
    dd if=/dev/zero bs=1 count=1
    # chksum tbd (8 bs)
    echo -n '        '
    # typeflag (1 b)
    echo -n 'g'
    # linkname (100 bs)
    dd if=/dev/zero bs=100 count=1
    # magic (6 bs)
    echo -n 'ustar'
    dd if=/dev/zero bs=1 count=1
    # version (2 bs)
    echo -n '00'
    # uname (32 bs)
    echo -n 'root'
    dd if=/dev/zero bs=28 count=1
    # gname (32 bs)
    echo -n 'root'
    dd if=/dev/zero bs=28 count=1
    # devmajor (8 bs)
    echo -n '0000000'
    dd if=/dev/zero bs=1 count=1
    # devminor (8 bs)
    echo -n '0000000'
    dd if=/dev/zero bs=1 count=1
    # prefix (155 bs)
    dd if=/dev/zero bs=155 count=1
    # 512-500 bs 512-byte block padding
    dd if=/dev/zero bs=12 count=1
  } > "${TMP_DIR}/intermediate_global_header"
  # print out header with proper checksum
  dd if="${TMP_DIR}/intermediate_global_header" bs=148 count=1
  create_tar_header_chksum "${TMP_DIR}/intermediate_global_header"
  dd if="${TMP_DIR}/intermediate_global_header" skip=156 bs=1 count=356
  cat "$TMP_DIR/tmp_pax_headers"
  header_bs="$((512-header_bs%512))"
  # padding for the rest of the 512-byte block
  if [ "$header_bs" -gt 0 ] && [ ! "$header_bs" -eq 512 ]; then
    dd if=/dev/zero bs="$header_bs" count=1
  fi
}
outer_tar_prefix() (
  # The purpose of this function is to create a subshell which is equivalent to
  # running `tar --format pax -c file.tar` which creates an outer tar header
  # but only outputting the header without the rest of the tar file.
  # This enables writing out a tar file to stdout in intermediate parts rather
  # than requiring double the space for creating the cache.
  set +o pipefail
  tar --format pax -c "$1" 2>/dev/null | {
    dd bs=512 count=1 of="$TMP_DIR/prefix_header"
    pax_header_size=0
    if [ "$(getTarTypeflag "$TMP_DIR/prefix_header")" = x ]; then
      pax_header_size="$(ustarSize < "$TMP_DIR/prefix_header")"
      dd_max_read "$pax_header_size" > "$TMP_DIR/prefix_header_body"
      dd bs=512 count=1 > "$TMP_DIR/prefix_header_file"
    fi
    if [ "${enforce_integrity}" = true ]; then
      prefix_files+=( "$TMP_DIR/global_header" )
      file_checksum="$(<"$TMP_DIR"/tar-checksum)"
      if [ "$pax_header_size" -gt 0 ]; then
        pax_checksum="$(trim=1 dd_max_read "$pax_header_size" < "$TMP_DIR/prefix_header_body" | checksum_data -)"
      else
        # no checksum because no pax header
        pax_checksum="0"
      fi
      pax_global_integrity_header "$pax_checksum" "$file_checksum" > "$TMP_DIR/global_header"
      local global_header_bs
      global_header_bs="$(stat_file_size "$TMP_DIR/global_header")"
      if [ ! "$global_header_bs" = 1024 ]; then
        echo "ERROR: pax global header size (expected 1024): $global_header_bs" >&2
        exit 1
      fi
    fi
    verify_tar_chksum "$TMP_DIR/prefix_header"
    prefix_files+=( "$TMP_DIR/prefix_header" )
    if [ "$pax_header_size" -gt 0 ]; then
      verify_tar_chksum "$TMP_DIR/prefix_header_file"
      prefix_files+=( "$TMP_DIR/prefix_header_body" "$TMP_DIR/prefix_header_file" )
    fi
    # create tar prefix
    cat "${prefix_files[@]}"
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
preflight_checks
mode="extract"
full_paths=()
relative_paths=()
nosudo=false
largetar_dir="${TMP_DIR}"
enforce_integrity=false
xxh_size=1
sha_size=1
sum_util=shasum
disable_integrity_detection=false
if type -P xxhsum > /dev/null; then
  sum_util=xxhsum
fi
export largetar_dir nosudo enforce_integrity
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
    -s|--verify-checksum)
      enforce_integrity=true
      shift
      ;;
    -H|--xxh)
      if ! algorithm_supported xxhsum "${2:-}"; then
        echo 'ERROR: Only --xxh 1-3 supported.' >&2
        exit 1
      fi
      sum_util=xxhsum
      enforce_integrity=true
      xxh_size="$2"
      shift
      shift
      ;;
    -a|--sha)
      if ! algorithm_supported shasum "${2:-}"; then
        echo 'ERROR: Only --sha 1 or --sha 256 supported.' >&2
        exit 1
      fi
      sum_util=shasum
      enforce_integrity=true
      sha_size="$2"
      shift
      shift
      ;;
    --no-detect)
      disable_integrity_detection=true
      shift
      ;;
    /*)
      full_paths+=( "${1#/}" )
      shift
      ;;
    -*)
      echo 'ERROR: unrecognized option'" '$1'" >&2
      exit 1
      ;;
    *)
      relative_paths+=( "$1" )
      shift
      ;;
  esac
done
if [ "$mode" = extract ]; then
  if [ -w /dev/shm ]; then
    rmdir "$TMP_DIR"
    # Use in-memory storage on extraction when available since scratch space
    # will be very small.
    TMP_DIR="$(mktemp -d -p /dev/shm)"
  fi
  PAXTAR_HEADER="$TMP_DIR/outer_tar"
  TAR_HEADER="$TMP_DIR/inner_tar"
  PAX_HEADER="$TMP_DIR/pax_header"
  PAX_GLOBAL_HEADER="$TMP_DIR/global_pax_header"
  extract
else
  # create
  if [ -z "${full_paths:-}" ] && [ -z "${relative_paths:-}" ]; then
    echo 'ERROR: Nothing to create.  No file paths were provided as args.' >&2
    exit 1
  fi
  if [ -n "${full_paths:-}" ]; then
    (
      archive_command=()
      if [ "$nosudo" = false ]; then
        archive_command+=( sudo )
      fi
      archive_command+=( tar --format pax -cC / -- "${full_paths[@]}" )
      echo "${archive_command[*]}" >&2
      if [ "${enforce_integrity}" = true ]; then
        "${archive_command[@]}" | stream_checksum create "${largetar_dir}/os-cache.tar"
      else
        "${archive_command[@]}" > "${largetar_dir}/os-cache.tar"
      fi
      cd "${largetar_dir}"
      # same as `tar --format pax -c os-cache.tar` except it does not
      # write the end or archive marker.
      outer_tar_prefix os-cache.tar > "$TMP_DIR"/os-cache-prefix
      cat "$TMP_DIR"/os-cache-prefix os-cache.tar
      rm -f os-cache.tar
    )
  fi
  if [ -n "${relative_paths:-}" ]; then
    (
      archive_command=( tar --format pax -c -- "${relative_paths[@]}" )
      echo "${archive_command[*]}" >&2
      if [ "${enforce_integrity}" = true ]; then
        "${archive_command[@]}" | stream_checksum create "${largetar_dir}/pwd-cache.tar"
      else
        "${archive_command[@]}" > "${largetar_dir}/pwd-cache.tar"
      fi
      cd "${largetar_dir}"
      outer_tar_prefix pwd-cache.tar > "$TMP_DIR"/pwd-cache-prefix
      cat "$TMP_DIR"/pwd-cache-prefix pwd-cache.tar
      rm -f pwd-cache.tar
    )
  fi
  # End of pax tar archive is two 512-byte blocks of all zeros.
  dd if=/dev/zero bs=1024 count=1
fi
