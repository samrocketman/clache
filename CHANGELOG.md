# clache v0.16 - May 28, 2026

Backwards incompatible for caches created with `-H 0` option; migrate to `-H 1`
before upgrading.

- Bugfixed coredump when using `--sha 1` or `--sha 256` algorithm.  Bug
  introduced by v0.15.
- Removed support for xxh32 (`xxhsum -H0`).  It does not particularly stand out
  in benchmarks and it is not recommended for verifying file integrity due to
  the amount of collisions.
- Removed static alpine checks and switched to capability-based checks.  This
  means some prerequisites known to have compatibility problems get checked on
  the utility level making them more reliable to determine errors as early as
  possible.
- Invalid options now throw an error.  This also means that relative files which
  start with a hypen are not supported.  I'm okay with this.

Other chores

- Clarified integrity checking archive documentation.
- Added tests for more reliable pre-release checking.

# clache v0.15 - May 27, 2026

- Support added for alpine Linux with required packages documented.
- If `shasum` is not available, but `sha1sum` and `sha256sum` are available,
  then `clache.sh` will gracefully fall back.

# clache v0.14 - May 27, 2026

- Fix end of archive checking which was removed in v0.12.
- Algorithm detection is more precise.

# clache v0.13 - May 26, 2026

- Algorithm information now stored in the PAX Global Header when an integrity
  checking archive is created.

# clache v0.12 - May 26, 2026

Major changes:

- Encountering unexpected files in the archive will now cause `clache.sh` to
  exit in error.  This makes it even more strict in its file format which is
  fine because it's special purpose.
- Instead of reading unlimited files from the archive only two are read.  This
  is also part of increasing file format strictness in `clache.sh`.

Bugs fixed:

- Bugfix silent failure when creating archives with invalid tar headers.  When
  creating a tar, intermediate header data now has its chksum field verified as
  a quick validity check.

Other changes:

- Clean up some old code and other bash hygiene.
- PAX record limit reduced from 1k to 50 tightening the limit further.
- Fix minor PAX Global Header padding bug which was impossible to trigger but
  fixing for logic correctness.
- Internal function `get_pax_field` only reads first 1KB instead of entire pax
  header data when checking record data.

# clache v0.11 - May 26, 2026

- Support for integrity checking archive.  Detects cache corruption after the
  archive was created.
  - Auto-detection on extraction with an option to skip detection with
    `--no-detect`.
  - `xxhsum -H1` is default falling back to `shasum -a 1` if not available.
  - Support for specifying a hash algorithm to checksum data.
    - `--sha [1|256]`
    - `--xxh [0|1|2|3]`
- Bugfix: End of archive could hide corruption or a truncated archive with
  partial read.

# clache v0.10 - May 25, 2026

Bugs fixed:

- Internal function `dd_max_read` fixes so `bs=0` is not possible.
- Fixed desynchronized parser bug where dd may not fully read the block data.

Security issues fixed:

- Fix hang on too many pax records.  Pax record limit is now 1000.
- UTF-8 control characters are now stripped in sanitizing logic.

# clache v0.9 - May 25, 2026

- Internal function `dd_max_read` reads only what is necessary.
- Fixed ustar bug where `prefix` field was not considered for the file name.
- Added a proposal for cache integrity checking to detect corruption.

# clache v0.8 - May 24, 2026

More robust tar handling surfacing failures as soon as possible.

- `/dev/shm` in-memory file system used, when available, extracting caches.
- Locale issues removed by using `LC_ALL` where ASCII is required.
- `ustar` checksum validation ensures header correctness.
- Sanitize nonoctal characers in ustar size field.
- End of archive is a little more robust against truncated EOF.
- More robust inner tar header parsing.
  - Inner tar header checksum validated.
  - Inner tar files are unpractically limited to 10TB.
  - Inner tar has typeflag validation in addition to format validation.
- More robust pax header parsing using dd for bytes seeking.
  - pax headers are practically limited to 5MB.
  - Lots of cross checking when reading pax headers sequentially.
  - Sanitize nonnumeric characters in pax size field.
  - pax headers cannot seek outside of the pax header bounds.


# clache v0.7 - May 23, 2026

- Echo statements show pax format and root path.

# clache v0.6 - May 23, 2026

- Bugfix sanitizing nonascii characters.  Previously alphanumeric by mistake.

# clache v0.5 - May 23, 2026

More defensive validation

- Validate pax inner tar is ustar format
- More nonascii sanitizing like size and other fields.
- ustar name is always ASCII

# clache v0.4 - May 23, 2026

- More strict inspection of tar format: sanitize non-ASCII and shell control
  characters from key fields.  To avoid a binary file introducing control
  characters in echo output.
- Remove `--ignore-failed-read` option since it is not widely supported.
- Minor change to one echo.
- Shellcheck utility passes.

# clache v0.3 - May 21, 2026

- Fix writing to stderr for informational messages.

# clache v0.2 - May 20, 2026

- Optimal extraction throughput by using 5MB block size instead of 512 byte
  block size.  Ensures `dd` is not a bottleneck.

# clache v0.1 - May 20, 2026

- Initial release
- Creates and extracts archives using as little intermediate disk space as
  feasible.  Creating the cache is the most expensive since whole intermediate
  archives must be written to disk in order for files to be added to tar.
  Extraction is extremely lightweight writing only a few KB to disk.
- Supported tar formats:
  - Creating archives: pax(ustar) from both GNU and BSD tar utils.
  - Extracting archives: ustar and pax(ustar) from both GNU and BSD tar utils.
