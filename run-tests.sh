#!/bin/bash
# Runs VantaInc/vanta-agent-scripts/install-linux.sh against stub commands, so every branch can
# be exercised on any machine without root, dpkg, network access or a Vanta key.
#
# Each case gets a fresh sandbox:
#   - a copy of install-linux.sh with only its hard-coded system paths rewritten into the
#     sandbox (product_uuid, /var/vanta/vanta-cli) and the expected checksum set to the fixture's
#   - a bin/ directory that is the ONLY thing on PATH: real coreutils are symlinked in, and
#     curl, sudo, dpkg, lsb_release, sleep and the hashing tools are small stubs that log calls
#
# Usage: ./run-tests.sh [path/to/install-linux.sh]
set -u

SCRIPT="${1:-vanta-agent-scripts/install-linux.sh}"
if [ ! -f "$SCRIPT" ]; then
  git clone -q https://github.com/VantaInc/vanta-agent-scripts.git
fi
PASS=0
FAIL=0
ROOT="$(mktemp -d)"
FIXTURE_CONTENT="fake vanta deb"

make_sandbox() { # $1 = name; sets $SB
  SB="$ROOT/$1"
  mkdir -p "$SB/bin" "$SB/var/vanta" "$SB/dmi"
  for tool in bash grep uname cat mktemp rm cut env tr; do
    ln -s "$(command -v $tool)" "$SB/bin/$tool"
  done
  echo "4c4c4544-0042-3510-8058-b4c04f4e3732" > "$SB/dmi/product_uuid"
  printf '%s' "$FIXTURE_CONTENT" > "$SB/fixture.deb"
  local sum
  sum=$(printf '%s' "$FIXTURE_CONTENT" | shasum -a 256 | cut -d' ' -f1)
  sed -e "s|/sys/class/dmi/id/product_uuid|$SB/dmi/product_uuid|" \
      -e "s|/var/vanta/vanta-cli|$SB/var/vanta/vanta-cli|" \
      -e "s|^DEB_CHECKSUM=.*|DEB_CHECKSUM=\"$sum\"|" "$SCRIPT" > "$SB/install-linux.sh"

  cat > "$SB/bin/lsb_release" <<'S'
#!/bin/bash
echo "Description:	Ubuntu 24.04 LTS"
S
  cat > "$SB/bin/sudo" <<'S'
#!/bin/bash
exec "$@"
S
  cat > "$SB/bin/sleep" <<'S'
#!/bin/bash
exit 0
S
  # curl: copy the fixture to --output, or emulate a 403 error page (curl exits 0 without --fail)
  cat > "$SB/bin/curl" <<S
#!/bin/bash
echo "curl \$*" >> "$SB/calls.log"
out=""
fail=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--output" ] || [ "\$1" = "-o" ]; then out="\$2"; shift; fi
  if [ "\$1" = "--fail" ] || [ "\$1" = "-f" ]; then fail=1; fi
  shift
done
if [ -n "\${STUB_HTTP_403:-}" ] && [ -n "\$fail" ]; then
  echo "curl: (22) The requested URL returned error: 403" >&2
  exit 22
elif [ -n "\${STUB_HTTP_403:-}" ]; then
  printf '<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>' > "\$out"
else
  cat "$SB/fixture.deb" > "\$out"
fi
S
  cat > "$SB/bin/dpkg" <<S
#!/bin/bash
echo "dpkg \$* VANTA_KEY=\${VANTA_KEY:-} VANTA_REGION=\${VANTA_REGION:-}" >> "$SB/calls.log"
S
  cat > "$SB/bin/shasum" <<'S'
#!/bin/bash
exec /usr/bin/shasum "$@"
S
  cat > "$SB/var/vanta/vanta-cli" <<'S'
#!/bin/bash
[ -z "${STUB_NOT_REGISTERED:-}" ]
S
  chmod +x "$SB"/bin/* "$SB/var/vanta/vanta-cli"
}

run_case() { # $1 = name, rest = env assignments; sets OUT and CODE (and saves OUT for -v)
  local name="$1"; shift
  OUT=$(cd "$SB" && env -i HOME="$SB" PATH="$SB/bin" VANTA_KEY=test-key \
    VANTA_OWNER_EMAIL=owner@example.com VANTA_REGION=us "$@" \
    bash ./install-linux.sh 2>&1)
  CODE=$?
  printf '%s\n' "$OUT" > "$ROOT/$name.out"
  if [ -n "${VERBOSE:-}" ]; then printf '%s\n' "$OUT" | sed 's/^/      | /'; fi
}

check() { # $1 = description, $2 = condition result (0 = true)
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"
  fi
}
has() { printf '%s' "$OUT" | grep -q -- "$1"; }

echo "1. happy path"
make_sandbox happy
run_case happy
check "exits 0" $([ $CODE -eq 0 ]; echo $?)
check "prints 'Checksums match.'" $(has "Checksums match."; echo $?)
check "runs dpkg -Ei with VANTA_KEY passed through sudo" $(grep -q "dpkg -Ei .*vanta.deb VANTA_KEY=test-key VANTA_REGION=us" "$SB/calls.log"; echo $?)

echo "2. no shasum or sha256sum on PATH"
make_sandbox nohash
rm "$SB/bin/shasum"
run_case nohash
check "warns that the checksum is not checked" $(has "shasum is not installed"; echo $?)
check "does NOT also claim 'Checksums match.'" $(has "Checksums match."; [ $? -ne 0 ]; echo $?)

echo "3. download returns an HTTP 403 error page"
make_sandbox http403
run_case http403 STUB_HTTP_403=1
check "exits non-zero" $([ $CODE -ne 0 ]; echo $?)
check "does not run dpkg" $(grep -q "^dpkg" "$SB/calls.log" 2>/dev/null; [ $? -ne 0 ]; echo $?)
check "reports a download failure, not a checksum mismatch" $(has "Checksums do not match"; [ $? -ne 0 ]; echo $?)

echo "4. agent installs but never registers (behavior note)"
make_sandbox noreg
run_case noreg STUB_NOT_REGISTERED=1
check "prints the registration warning" $(has "Could not verify that Vanta Device Monitor is registered"; echo $?)
# The script ends this branch with an explicit `exit 0`, so this looks deliberate. Recorded
# as current behavior rather than a failure.
check "exits 0 anyway (current behavior, explicit exit 0)" $([ $CODE -eq 0 ]; echo $?)

echo
echo "$PASS passed, $FAIL failed"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
