#!/usr/bin/env bash
#
# Install a markfluence release onto a GitHub Actions runner and put it on
# PATH. Shared by both actions in this repository:
#
#   setup/action.yml  ->  "$GITHUB_ACTION_PATH/install.sh"
#   action.yml        ->  "$GITHUB_ACTION_PATH/setup/install.sh"
#
# It is a script rather than a nested action for a reason that is easy to trip
# over: a relative `uses: ./setup` inside a composite action resolves against
# $GITHUB_WORKSPACE -- the *consumer's* checkout -- not against this
# repository, so it would fail with "Can't find 'action.yml'" naming a path in
# their repo (actions/runner#1348). Sharing a script avoids that entirely.
#
# Inputs, all through the environment so no caller interpolates into a shell:
#   MARKFLUENCE_VERSION  a tag like v1.2.3, or "latest"
#
set -euo pipefail

readonly REPO="mozilla/markfluence"
readonly SLUG="markfluence"

die() {
    echo "::error::$*" >&2
    exit 1
}

# resolve_version turns "latest" into a concrete tag.
#
# Via the redirect on /releases/latest rather than the REST API, deliberately:
# the API would need a token to avoid a shared unauthenticated rate limit, and
# a setup action that demands a token just to install a binary is a bad trade.
#
# This is only trustworthy because the release workflow creates each release as
# a draft and publishes it last -- /releases/latest is the most recent
# *published* non-prerelease and does not care whether its assets finished
# uploading. Without that, a half-failed release would be what "latest"
# resolves to. See docs/releasing.md.
resolve_version() {
    local url
    url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
        "https://github.com/${REPO}/releases/latest")" ||
        die "could not reach github.com to resolve the latest markfluence release"
    local tag="${url##*/tag/}"
    # Spelled as an if rather than `A && B || C`, which shellcheck flags
    # (SC2015) because C also runs when A succeeds and B fails -- correct
    # here by luck rather than by construction, and the next edit would not
    # be.
    if [ "$tag" = "$url" ] || [ -z "$tag" ]; then
        die "could not read a tag out of the /releases/latest redirect (got: ${url})"
    fi
    printf '%s' "$tag"
}

# platform prints goreleaser's os_arch for this runner, or fails by name.
#
# The mapping is not identity in either half: $RUNNER_OS is Linux/macOS/Windows
# where goreleaser writes linux/darwin, and $RUNNER_ARCH is X64/ARM64 where it
# writes amd64/arm64.
#
# The unsupported platforms fail with a message rather than a 404 on the
# download. Because this repository is its own Homebrew tap, the release build
# matrix is also the install matrix, so a platform missing here is missing on
# purpose -- Windows has never been built, and Intel macOS was dropped once
# macOS 26 became Apple's last Intel release (#180).
platform() {
    local os arch
    case "${RUNNER_OS:-}" in
        Linux) os=linux ;;
        macOS) os=darwin ;;
        Windows)
            die "markfluence publishes no Windows build, so this action cannot run on a Windows runner." \
                "Use ubuntu-latest, ubuntu-24.04-arm or macos-latest. If you need Windows, say so on" \
                "https://github.com/${REPO}/issues/29"
            ;;
        *) die "unrecognised RUNNER_OS '${RUNNER_OS:-}'; expected Linux or macOS" ;;
    esac
    case "${RUNNER_ARCH:-}" in
        X64) arch=amd64 ;;
        ARM64) arch=arm64 ;;
        *) die "unrecognised RUNNER_ARCH '${RUNNER_ARCH:-}'; expected X64 or ARM64" ;;
    esac
    if [ "$os" = darwin ] && [ "$arch" = amd64 ]; then
        # Worded carefully: markfluence *dropped* the Intel macOS build, it did
        # not always lack one, and releases from before that change still carry
        # a darwin_amd64 archive. Claiming none exists would be false for
        # anyone pinning one of those. This action does not install it either
        # way -- Intel macOS is not a supported target.
        die "this action does not support Intel macOS. markfluence dropped the darwin/amd64 build" \
            "because macOS 26 Tahoe is Apple's last Intel release; older releases still carry that" \
            "archive, but it is not installed here. Use macos-latest, which is Apple Silicon, or a" \
            "Linux runner. If you need Intel macOS: https://github.com/mozilla/markfluence-action/issues"
    fi
    printf '%s_%s' "$os" "$arch"
}

# verify checks one archive against the release's checksums.txt.
#
# The matching line is grepped out and piped in rather than using
# --ignore-missing over the whole file, which keeps this working the same way
# under GNU coreutils' sha256sum and macOS's Perl shasum. Both exist on their
# respective runners; neither exists on both.
verify() {
    local archive="$1" sums="$2" line
    # Matched on the exact filename field, not as a substring. `grep -F
    # "  ${archive}"` would also match a sibling whose name *extends* this one
    # -- a detached signature or an SBOM, which goreleaser's sign and sbom
    # pipes produce as `<archive>.sig` and `<archive>.sbom.json`. Two matching
    # lines make the check fail on a file that was never downloaded, and the
    # script would then report tampering for a perfectly good release.
    line="$(awk -v name="$archive" '$2 == name' "$sums")"
    [ -n "$line" ] ||
        die "checksums.txt has no entry for ${archive}; the release may be incomplete"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s\n' "$line" | sha256sum --check --status - ||
            die "checksum mismatch for ${archive} -- refusing to install"
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s\n' "$line" | shasum -a 256 --check --status - ||
            die "checksum mismatch for ${archive} -- refusing to install"
    else
        die "neither sha256sum nor shasum is available; cannot verify the download"
    fi
}

main() {
    local version="${MARKFLUENCE_VERSION:-latest}"
    # Both named here rather than failing later on `set -u`. Putting the binary
    # on PATH is the whole point of the action, so a missing GITHUB_PATH must
    # not surface as an unbound-variable error *after* a successful download.
    [ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is unset; this script expects to run on a GitHub Actions runner"
    [ -n "${GITHUB_PATH:-}" ] || die "GITHUB_PATH is unset; this script expects to run on a GitHub Actions runner"

    if [ "$version" = latest ]; then
        version="$(resolve_version)"
    fi
    # goreleaser's name_template uses .Version, which strips the leading v:
    # tag v1.2.3 produces markfluence_1.2.3_linux_amd64.tar.gz.
    local bare="${version#v}"
    local plat archive base dest
    plat="$(platform)"
    archive="${SLUG}_${bare}_${plat}.tar.gz"
    base="https://github.com/${REPO}/releases/download/${version}"
    dest="${RUNNER_TEMP}/markfluence-${bare}"

    mkdir -p "$dest"
    cd "$dest"

    curl -fsSLO "${base}/${archive}" ||
        die "could not download ${archive} from ${version}. Is that a real markfluence release?" \
            "Releases: https://github.com/${REPO}/releases"
    curl -fsSLO "${base}/checksums.txt" ||
        die "downloaded ${archive} but could not fetch checksums.txt from ${version}"
    verify "$archive" checksums.txt

    # Only the binary. The archive is flat and also carries README.md, LICENSE
    # and completions/, none of which belong on a runner.
    tar -xzf "$archive" "$SLUG"
    chmod +x "$SLUG"

    printf '%s\n' "$dest" >> "$GITHUB_PATH"

    # Smoke test, so a bad asset fails here rather than three steps later in
    # the middle of a publish.
    "./${SLUG}" --version ||
        die "${archive} installed but ./${SLUG} --version failed"

    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf 'version=%s\n' "$version" >> "$GITHUB_OUTPUT"
    fi
    echo "markfluence ${version} installed to ${dest}"
}

main "$@"
