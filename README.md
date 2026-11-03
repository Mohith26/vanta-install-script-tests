# vanta-install-script-tests

Tests for [VantaInc/vanta-agent-scripts](https://github.com/VantaInc/vanta-agent-scripts)'
`install-linux.sh`, the one-line installer for the Vanta Device Monitor on Debian/Ubuntu.

An installer like this is hard to test because it wants root, dpkg, a real hardware UUID, the
network and a Vanta key. `run-tests.sh` runs it in a sandbox instead: a copy of the script with
only its hard-coded system paths rewritten (`product_uuid`, `/var/vanta/vanta-cli`) and the
expected checksum set to a local fixture's, and a `bin/` directory that is the only thing on
`PATH`. Real coreutils are symlinked in; `curl`, `sudo`, `dpkg`, `lsb_release`, `sleep` and
`shasum` are small stubs that log their calls. No root and no network needed.

## What it found (against agent 2.21.0, commit 06ab7c1)

```
$ ./run-tests.sh
1. happy path
  ok    exits 0
  ok    prints 'Checksums match.'
  ok    runs dpkg -Ei with VANTA_KEY passed through sudo
2. no shasum or sha256sum on PATH
  ok    warns that the checksum is not checked
  FAIL  does NOT also claim 'Checksums match.'
3. download returns an HTTP 403 error page
  ok    exits non-zero
  ok    does not run dpkg
  FAIL  reports a download failure, not a checksum mismatch
4. agent installs but never registers (behavior note)
  ok    prints the registration warning
  ok    exits 0 anyway (current behavior, explicit exit 0)

8 passed, 2 failed
```

1. **No hashing tool:** the script warns that it is not checking the package, sets
   `CHECKSUM=""`, and then runs `[ $downloaded_checksum = $CHECKSUM ]` with both unset. Unquoted,
   that becomes `[ = ]`, which is true, so the log also says "Checksums match." even though
   nothing was hashed.
2. **Download error:** `curl` runs without `--fail`, so a 403/404 error page is saved as
   `vanta.deb` and the user is told "Checksums do not match", which points at tampering rather
   than at the download.
3. **Not registered:** if registration can't be verified after 5 tries, the script prints a
   warning but ends with `exit 0`. That looks deliberate, so the test records it as current
   behavior; it does mean fleet tooling running the script sees success.

Also noticed (not tested): the script always installs `vanta-amd64.deb` and never checks the
machine's architecture. `agent-downloads.vanta.com/.../vanta-arm64.deb` returns 403, so on an
arm64 machine the failure would come from dpkg after the download and checksum.

## Proposed fix

`proposed/install-linux.patch` (7 lines) adds `--fail` with a clear download error and skips
the comparison when there is no hashing tool. With it applied:

```
$ ./run-tests.sh proposed/install-linux.sh
...
10 passed, 0 failed
```

## Run it

```sh
./run-tests.sh                      # clones vanta-agent-scripts and tests install-linux.sh
./run-tests.sh path/to/install-linux.sh
VERBOSE=1 ./run-tests.sh            # also prints the installer's output
```

Needs bash and git; works on macOS and Linux.
