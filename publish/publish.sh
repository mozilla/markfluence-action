#!/usr/bin/env bash
#
# Publish changed markdown files to Confluence with markfluence.
#
# Invoked by the publish action at the repository root, through
# $GITHUB_ACTION_PATH. See setup/install.sh for why the logic lives in a
# script rather than a nested action.
#
# Inputs, all through the environment so no caller interpolates into a shell:
#   MARKFLUENCE_FILES         the glob, before any narrowing
#   MARKFLUENCE_CHANGED_ONLY  true|false
#   MARKFLUENCE_SINCE         explicit base ref, or empty
#   MARKFLUENCE_DRY_RUN       true|false
#   MARKFLUENCE_DEBUG         true|false
#
# Credentials are NOT inputs. markfluence reads CONFLUENCE_* from the
# environment and refuses a token as a command-line flag at all, so a secret
# never becomes an action input that could be echoed.
#
set -euo pipefail

die() {
    echo "::error::$*" >&2
    exit 1
}

# base_ref prints the commit to diff against, or nothing when there is no
# usable base -- in which case the caller publishes everything instead of
# diffing.
#
# `since` wins when given. Otherwise it is the push event's `before` sha, and
# an all-zero value there is not an error: a new branch or a force-push
# reports one.
#
# The empty return matters. The obvious fallback -- diff against the first
# commit -- does NOT publish everything: a file added *in* that commit and
# never touched since does not appear in `root..HEAD`, so the files a
# repository started life with are silently skipped. (markfluence's own
# docs/github-actions.md recipe has that flaw; this does not.) Listing every
# matching file is the only thing that actually means "publish everything".
base_ref() {
    local since="${MARKFLUENCE_SINCE:-}"
    if [ -n "$since" ]; then
        git rev-parse --verify --quiet "$since" >/dev/null ||
            die "since: '${since}' does not resolve to a commit in this checkout." \
                "A shallow clone is the usual cause -- see fetch-depth below."
        printf '%s' "$since"
        return
    fi
    local before="${GITHUB_EVENT_BEFORE:-}"
    if [ -z "$before" ] || [ -z "${before//0/}" ]; then
        return
    fi
    git rev-parse --verify --quiet "$before" >/dev/null ||
        die "the push event's base commit ${before} is not in this checkout." \
            "Set fetch-depth: 0 on actions/checkout -- both ends of the push range have to be present."
    printf '%s' "$before"
}

# pathspecs turns the `files` input into git pathspec arguments, one per
# whitespace-separated pattern, and prints them NUL-separated.
#
# Each gets git's `:(glob)` magic prefix, and that is not cosmetic. As a plain
# pathspec, `docs/**/*.md` -- the documented default, and what a shell glob
# would mean -- matches `docs/sub/b.md` and **silently misses `docs/a.md`**,
# because plain `**` requires at least one intervening directory. The failure
# mode is a publish that quietly skips every top-level file. With `:(glob)`,
# `**` spans zero or more directories and `*` stops at `/`, which is exactly
# the shell-glob semantics the input is written to look like.
#
# A pattern that already starts with `:` is passed through untouched, so a
# caller can still use magic of their own -- `:!docs/private/**` to exclude,
# for instance.
pathspecs() {
    local pat
    for pat in ${MARKFLUENCE_FILES}; do
        case "$pat" in
            :*) printf '%s\0' "$pat" ;;
            *)  printf ':(glob)%s\0' "$pat" ;;
        esac
    done
}

# changed_files writes the files to publish, one per line, to $1.
#
# --diff-filter=ACMRT is load-bearing: it excludes deletions. A deleted file
# in the list fails the run, since markfluence cannot publish a file that is
# not there, and deleting a page is deliberately not something a publish does.
changed_files() {
    local out="$1" base head
    [ "$(git rev-parse --is-shallow-repository)" = false ] ||
        die "this is a shallow clone, so the push range cannot be resolved." \
            "Set fetch-depth: 0 on actions/checkout."
    base="$(base_ref)"
    if [ -z "$base" ]; then
        echo "No usable base commit (a new branch or a force-push reports none), so publishing everything."
        all_files "$out"
        return
    fi
    head="${GITHUB_SHA:-HEAD}"
    echo "Diffing ${base}..${head}"
    pathspecs | xargs -0 git diff --name-only --diff-filter=ACMRT "$base" "$head" -- > "$out"
}

# all_files writes every file matching the pathspec to $1, via git rather than
# a shell glob so that the pattern means the same thing in both paths.
all_files() {
    local out="$1"
    pathspecs | xargs -0 git ls-files -- > "$out"
}

main() {
    [ -n "${MARKFLUENCE_FILES:-}" ] || die "files: is empty; give it a glob such as 'docs/**/*.md'"
    [ -n "${GITHUB_OUTPUT:-}" ] || die "GITHUB_OUTPUT is unset; this expects to run on a GitHub Actions runner"
    command -v markfluence >/dev/null 2>&1 ||
        die "markfluence is not on PATH. The publish action installs it itself, so this is a bug --" \
            "please report it: https://github.com/mozilla/markfluence-action/issues"

    local list results
    list="$(mktemp)"
    results="${RUNNER_TEMP:-/tmp}/markfluence-results.json"

    if [ "${MARKFLUENCE_CHANGED_ONLY:-true}" = true ]; then
        changed_files "$list"
    else
        all_files "$list"
    fi

    local count
    count="$(wc -l < "$list" | tr -d ' ')"
    echo "count=${count}" >> "$GITHUB_OUTPUT"

    if [ "$count" -eq 0 ]; then
        # Not a failure, and not something to paper over by invoking markfluence
        # anyway: `update` with no FILE arguments is an error.
        echo "No matching files changed; nothing to publish."
        {
            echo "published=0"
            echo "skipped=0"
            echo "failed=0"
            echo "results-json="
        } >> "$GITHUB_OUTPUT"
        echo "### markfluence: nothing to publish" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
        return 0
    fi

    echo "Publishing ${count} file(s):"
    sed 's/^/  /' "$list"

    # --force is not configurable, and that is deliberate. CI is the
    # arrangement where the repository is the source of truth, so a Confluence
    # UI edit is drift rather than work. Without it, whether a page publishes
    # depends on a local action log that a fresh checkout does not have, and
    # files get reported `skipped` for a reason nobody in CI can act on. An
    # action that can be configured into that state is a trap.
    local args=(update --force --json)
    [ "${MARKFLUENCE_DRY_RUN:-false}" = true ] && args+=(--dry-run)
    [ "${MARKFLUENCE_DEBUG:-false}" = true ] && args+=(--debug)

    # The exit status is captured rather than allowed to kill the script: the
    # JSON on stdout is worth reporting either way, and the step should fail
    # *after* the outputs and summary are written.
    local status=0
    xargs markfluence "${args[@]}" < "$list" > "$results" || status=$?

    summarize "$results" "$status"
    return "$status"
}

# summarize turns the envelope into step outputs and a run summary.
#
# Reading the schema-locked --json rather than scraping human output, which is
# the whole reason markfluence has a published schema. jq is preinstalled on
# every GitHub-hosted runner.
summarize() {
    local results="$1" status="$2"
    if ! jq -e . "$results" >/dev/null 2>&1; then
        # markfluence died before emitting a document -- bad credentials, say.
        # Its stderr has already been printed; do not hide that behind a jq
        # parse error.
        echo "::error::markfluence exited ${status} without emitting JSON; see the log above"
        {
            echo "published=0"
            echo "skipped=0"
            echo "failed=0"
            echo "results-json="
        } >> "$GITHUB_OUTPUT"
        return
    fi

    local published skipped failed
    published="$(jq -r '.summary.succeeded // 0' "$results")"
    skipped="$(jq -r '.summary.skipped // 0' "$results")"
    failed="$(jq -r '.summary.failed // 0' "$results")"

    {
        echo "published=${published}"
        echo "skipped=${skipped}"
        echo "failed=${failed}"
        # The path, not the contents: a multi-line JSON document in a step
        # output is a quoting hazard, and the file is right there.
        echo "results-json=${results}"
    } >> "$GITHUB_OUTPUT"

    # --json silences human output entirely, so without this the log says
    # nothing about what happened.
    {
        echo "### markfluence"
        echo
        echo "| | count |"
        echo "|---|---|"
        echo "| published | ${published} |"
        echo "| skipped | ${skipped} |"
        echo "| failed | ${failed} |"
        echo
        jq -r '.results[]? | "- `\(.file // "?")` — \(if .ok then "ok" else "**failed**: \(.error // "unknown")" end)"' \
            "$results"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

    jq -r '.results[]? | select(.ok | not) | "::error file=\(.file // "")::\(.error // "failed")"' "$results"
}

main "$@"
