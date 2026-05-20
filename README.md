# clache

A CLI based generic CI/CD cache utility intended to create or extract caches
from streams.  Ideal for ephemeral systems where cloud object storage is
available to save and restore state across ephemeral nodes.

No AI was used to create this project.

## Examples

Create the cache.

```bash
clache.sh -n -c ~/.m2/repository target | aws s3 cp - s3://your-bucket/file.tar
```

Extracting the cache from stdin without writing full tar files to disk (a few KB
of header data gets written during stream inspection).

```bash
aws s3 cp s3://your-bucket/file.tar - | clache.sh -n -e
```

# Project description

[clache.sh](clache.sh) is intended for CI systems to be able to create and
extract a cache using streams.  Use case would be a cloud object store
downloading a file and streaming the download into this script.  This script
then handles all extraction via stdin without writing large tar files to disk.

Create cache strategy: Files and folders that will be added to the cache will be
broken up into two tar commands.

1. `sudo tar` (sudo can be opt-out) from the system root when full paths are
   given for permissions preservation.  If you have an ephemeral system which
   does not allow `sudo tar`, then use the `--nosudo` option documented below.
2. Non-sudo tar for file paths relative to the current working directory.

Extraction happens in the same two phases:

1. `sudo tar -xC /` for full path names.  `--nosudo` means just `tar -xC /` is
   run.
2. `tar -x` for relative path names.

# Creating tars without clache.sh script

If you create the outer and inner tar files without this script, then tar
files should always be created with one of the following commands.

    tar --format ustar -c ...
    tar --format pax -c ...

Expected tar layout:

    your-cache.tar
      |- agent-os-cache.tar - the sudo-created tar file.
      |- agent-workspace-cache.tar - working directory tar file.

# Tar support

Only ustar and pax(ustar) file formats supported. See [opengroup pax
publication].

# Help doc

`./clache.sh -h` results in the following.

```
clache.sh [--nosudo] --extract < tar-to-extract.tar
clache.sh [--nosudo] --create FILE... > tar-to-create.tar

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
```

[opengroup pax publication]: https://pubs.opengroup.org/onlinepubs/009695399/utilities/pax.html
