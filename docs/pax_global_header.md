# Proposal for cache integrity checking

Not all storage solutions where a cache archive would be stored can guarantee
integrity.  I would like a mechanism which provides integrity checking when
creating and extracting cache archives.

Goals:

- Extraction and checksumming should only operate on streams with very little
  data touching disk.
- Corruption in the cache file should be detectected.

Notes:

- There's two archive types contained in a clache archive.  `os-cache.tar` which
  contain full paths archived and `pwd-cache.tar` which contain paths from the
  current working directory.
- For each archive, there's a file pax header whose data checksum can be
  calculated and the archive itself can have its checksum calculated.
- The global pax header comes first with precomputed checksums, followed by the
  file pax header which can be validated against a precomputed checksum,
  followed by the archive which can be extracted and validated against a
  precomputed checksum.
- `clache.sh` should exit non-zero and fail whatever CI process is using it.
  Because tar extracts files a failure from `clache.sh` should be considered
  corruption in the currently running OS itself.

## Pax global header for integrity

Since this is a cache being processed from stdin intended from block storage
services it makes sense to try to also add integrity checking as an optional
feature.  Relying on pax global headers makes sense here.

There's not an easy way to generate pax global headers so this document is
intended to assist me manually generating the binary.

Creation procedure if checksum enabled:

- Both the archive and file pax header for the archive exist during creation.
- Create a global pax header with a sha256 checksum of both file pax header and
  archive.
- Write out: global pax header, file pax header, the archive.

Validation procedure for each archive encountered if checksum enabled:

- If global pax header encountered, then read it.
- If checksum enabled and global pax header does not exist, then exit in error.
- Read checksum data for both file pax header and archive.
- If either file pax header or archive checksums do not exist, then exit in
  error.
- Read the file pax header.  Calculate its checksum;
- If file pax header checksum failed, then exit in error.
- Read and extract (via `tee`) the archive.  Checksum calculates on the fly.
- If archive checksum failed, then exit in error.

The structure of this integrity-based archive is very strict. Blocks out of
order is considered corrupted and it will exit in error (e.g. if global header
is encountered after the pax header there will be an error surfaced even if
checksum is not required).

## Header block values

All values can be statically calculated.

| Field Name | offset | length | value                                      |
| ---------- | ------ | ------ | ------------------------------------------ |
| name       | 0      | 100    | `pax_global_integrity_header` (+nul 73 bs) |
| mode       | 100    | 8      | `0000666` (+nul)                           |
| uid        | 108    | 8      | `0000000` (+nul)                           |
| gid        | 116    | 8      | `0000000` (+nul)                           |
| size       | 124    | 12     | `00000000237` (+nul)                       |
| mtime      | 136    | 12     | `00000000000` (+nul)                       |
| chksum     | 148    | 8      | `0007499` (+nul)                           |
| typeflag   | 156    | 1      | `g`                                        |
| linkname   | 157    | 100    | (+nul 100 bs)                              |
| magic      | 257    | 6      | ustar (+nul)                               |
| version    | 263    | 2      | `00`                                       |
| uname      | 265    | 32     | `root` (+nul 28 bs)                        |
| gname      | 297    | 32     | `root` (+nul 28 bs)                        |
| devmajor   | 329    | 8      | `0000000` (+nul)                           |
| devminor   | 337    | 8      | `0000000` (+nul)                           |
| prefix     | 345    | 155    | (+nul 100 bs)                              |

The following script writes the static header and pre-calculates its octal
`chksum`.  The calculated octal result is 6413.

```bash
{
# name (100 bs)
echo -n 'pax_global_integrity_header'
dd if=/dev/zero bs=73 count=1 iflag=fullblock status=none
# mode (8 bs)
echo -n '0000666'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# uid (8 bs)
echo -n '0000000'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# gid (8 bs)
echo -n '0000000'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# size (12 bs)
echo -n '00000000237'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# mtime (12 bs)
echo -n '00000000000'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# chksum tbd (8 bs); results in: echo -n '0007499'
echo -n '       '
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# typeflag (1 b)
echo -n 'g'
# linkname (100 bs)
dd if=/dev/zero bs=100 count=1 iflag=fullblock status=none
# magic (6 bs)
echo -n 'ustar'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# version (2 bs)
echo -n '00'
# uname (32 bs)
echo -n 'root'
dd if=/dev/zero bs=28 count=1 iflag=fullblock status=none
# gname (32 bs)
echo -n 'root'
dd if=/dev/zero bs=28 count=1 iflag=fullblock status=none
# devmajor (8 bs)
echo -n '0000000'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# devminor (8 bs)
echo -n '0000000'
dd if=/dev/zero bs=1 count=1 iflag=fullblock status=none
# prefix (155 bs)
dd if=/dev/zero bs=155 count=1 iflag=fullblock status=none
# 512-500 bs 512-byte block padding
dd if=/dev/zero bs=12 count=1 iflag=fullblock status=none
} | od -v -A n -t u1 | xargs | tr ' ' '+' | bc
```

## Integrity Data

Global headers and their values:

* Following pax header sha256 for verifying integrity.
* The following file sha256 for verifying integrity.

Header data where the checksum is just an example.

```
79 pax_sha256=5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
80 file_sha256=5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
```

Pre-computed data and blocks:

- The header is always 159 bytes (octal `237`).
- 512-byte block nul padding is always 353 bytes.
- Pax header checksum is always octal 6413.

## Calculating checksum on the fly

`tee` can be used to calculate the checksum on the fly while passing data
through to tar for extraction at the same time.  The following script is a proof
of concept.

```bash
checksum_data() {
  tee >(echo "pax header$(shasum -a 256 -c /tmp/checksum; echo $? > /tmp/checksum-status)" >&2) | shasum -a 256
}
echo hello | checksum_data > /tmp/checksum 2> /dev/null
echo hello | checksum_data
echo hello2 | checksum_data
[ "$(</tmp/checksum-status)" = 0 ]
```
