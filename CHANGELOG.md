# clache v0.1 - May 20, 2026

- Initial release
- Creates and extracts archives using as little intermediate disk space as
  feasible.  Creating the cache is the most expensive since whole intermediate
  archives must be written to disk in order for files to be added to tar.
  Extraction is extremely lightweight writing only a few KB to disk.
- Supported tar formats:
  - Creating archives: pax(ustar) from both GNU and BSD tar utils.
  - Extracting archives: ustar and pax(ustar) from both GNU and BSD tar utils.
