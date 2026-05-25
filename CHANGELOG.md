# clache v0.9

- Internal function `dd_max_read` reads only what is necessary.

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
