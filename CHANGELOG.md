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
