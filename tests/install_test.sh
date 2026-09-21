#!/usr/bin/env bash
#
# Exercise setup/install.sh the way a runner does.
#
# This downloads real markfluence releases, so it needs network. That is
# deliberate rather than lazy: the thing under test is a downloader, and a
# test that stubs the download would only prove the stub works. The cost is
# that a network failure looks like a test failure.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT="${ROOT}/setup/install.sh"
# A real, published markfluence release. Bump only when this one goes away.
readonly KNOWN_TAG=v0.1.0

pass=0
fail=0

# run_install invokes install.sh in a throwaway runner environment and prints
# its combined output. Returns the script's exit status.
run_install() {
    local tmp
    tmp="$(mktemp -d)"
    (
        export RUNNER_TEMP="$tmp"
        export GITHUB_PATH="$tmp/github_path"
        export GITHUB_OUTPUT="$tmp/github_output"
        : > "$GITHUB_PATH"
        : > "$GITHUB_OUTPUT"
        export RUNNER_OS="$1" RUNNER_ARCH="$2" MARKFLUENCE_VERSION="$3"
        "$SCRIPT" 2>&1
        status=$?
        # Surface what the script told the runner, so assertions can see it.
        cat "$GITHUB_OUTPUT"
        exit $status
    )
    local status=$?
    rm -rf "$tmp"
    return $status
}

# ok NAME EXPECTED_STATUS EXPECTED_SUBSTRING RUNNER_OS RUNNER_ARCH VERSION
ok() {
    local name="$1" want_status="$2" want_text="$3"
    shift 3
    local out status
    out="$(run_install "$@")"
    status=$?
    if [ "$status" != "$want_status" ]; then
        printf 'FAIL %s\n     expected exit %s, got %s\n     output: %s\n' \
            "$name" "$want_status" "$status" "$out"
        fail=$((fail + 1))
        return
    fi
    if [ -n "$want_text" ] && [[ "$out" != *"$want_text"* ]]; then
        printf 'FAIL %s\n     expected output to contain: %s\n     output: %s\n' \
            "$name" "$want_text" "$out"
        fail=$((fail + 1))
        return
    fi
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
}

# The host decides which platform can actually run the downloaded binary, so
# the success cases are limited to it. Everything else is a refusal, which is
# platform-independent.
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) HOST_OS=macOS HOST_ARCH=ARM64 ;;
    Linux/x86_64) HOST_OS=Linux HOST_ARCH=X64 ;;
    Linux/aarch64) HOST_OS=Linux HOST_ARCH=ARM64 ;;
    *)
        echo "unsupported test host $(uname -s)/$(uname -m); skipping the install cases" >&2
        HOST_OS="" HOST_ARCH=""
        ;;
esac

if [ -n "$HOST_OS" ]; then
    # "latest" resolves through the /releases/latest redirect, installs, and
    # passes its own smoke test.
    ok 'latest installs and smoke-tests' 0 'markfluence ' "$HOST_OS" "$HOST_ARCH" latest
    # A pinned tag installs that tag, and the resolved version is reported
    # back to the runner as a step output.
    ok 'a pinned tag reports itself as an output' 0 "version=${KNOWN_TAG}" \
        "$HOST_OS" "$HOST_ARCH" "$KNOWN_TAG"
fi

# The two platforms markfluence does not build for must fail by name rather
# than on a download 404, because "404" does not tell a user whether they
# typoed a version or picked an unsupported runner.
ok 'Windows fails by name'    1 'no Windows build'    Windows X64   "$KNOWN_TAG"
ok 'Intel macOS fails by name' 1 'no Intel macOS build' macOS  X64   "$KNOWN_TAG"

# An unrecognised runner is a distinct failure from an unsupported one.
ok 'an unknown RUNNER_OS is named'   1 'unrecognised RUNNER_OS'   Plan9 X64   "$KNOWN_TAG"
ok 'an unknown RUNNER_ARCH is named' 1 'unrecognised RUNNER_ARCH' Linux S390X "$KNOWN_TAG"

# A version that does not exist names the version and points at the releases
# page, rather than surfacing curl's bare 404.
ok 'a nonexistent release is named' 1 'Is that a real markfluence release?' \
    Linux X64 v0.0.0-nope

# The checksum path is tested against `verify` directly rather than through a
# full install, because a mismatch cannot be provoked from outside: the
# archive and its checksums.txt both come from the same real release. Sourcing
# with the main call stripped is the smallest way to reach it.
verify_case() {
    local name="$1" want_status="$2" want_text="$3" archive="$4" sums="$5"
    local out status
    out="$(bash -c "source <(sed '/^main \"/d' '$SCRIPT'); verify '$archive' '$sums'" 2>&1)"
    status=$?
    if [ "$status" != "$want_status" ] || [[ -n "$want_text" && "$out" != *"$want_text"* ]]; then
        printf 'FAIL %s\n     exit %s (wanted %s), output: %s\n' "$name" "$status" "$want_status" "$out"
        fail=$((fail + 1))
        return
    fi
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
}

# Not in a subshell: `verify_case` increments the pass/fail counters, and a
# subshell would discard them -- which would report a green suite while a
# real failure went uncounted.
sums_dir="$(mktemp -d)"
cd "$sums_dir" || exit 1
echo 'the payload' > pkg.tar.gz
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum pkg.tar.gz > good.txt
else
    shasum -a 256 pkg.tar.gz > good.txt
fi
# Same filename, first hex digit replaced: a mismatch, not a missing entry.
sed 's/^./0/' good.txt > bad.txt

verify_case 'a matching checksum verifies'     0 ''                  pkg.tar.gz   good.txt
verify_case 'a tampered checksum refuses'      1 'checksum mismatch' pkg.tar.gz   bad.txt
verify_case 'an archive absent from checksums' 1 'no entry for'      other.tar.gz good.txt

cd "$ROOT" || exit 1
rm -rf "$sums_dir"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
