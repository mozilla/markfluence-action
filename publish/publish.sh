#!/usr/bin/env bash
#
# Publish changed markdown files to Confluence with markfluence.
#
# Invoked by the publish action at the repository root, through
# $GITHUB_ACTION_PATH. See setup/install.sh for why the logic lives in a
# script rather than a nested action.
#
# Inputs, all through the environment so no caller interpolates into a shell:
#   MARKFLUENCE_FILES         git pathspec(s), whitespace-separated
#   MARKFLUENCE_CHANGED_ONLY  true|false
#   MARKFLUENCE_SINCE         explicit base ref, or empty
#   MARKFLUENCE_DRY_RUN       true|false
#   MARKFLUENCE_DEBUG         true|false
#   GITHUB_EVENT_NAME         the triggering event
#   GITHUB_EVENT_BEFORE       push events only; the range's base sha
#   GITHUB_EVENT_PR_BASE_SHA  pull_request events only; the base sha
#
# Credentials are NOT inputs. markfluence reads CONFLUENCE_* from the
# environment and refuses a token as a command-line flag at all, so a secret
# never becomes an action input that could be echoed.
#
# Kept to bash 3.2: that is what /bin/bash is on a macOS runner, so no
# mapfile, no associative arrays, no ${var^^}.
#
set -euo pipefail

LIST=""
cleanup() { [ -n "$LIST" ] && rm -f "$LIST"; }
trap cleanup EXIT

die() {
    echo "::error::$*" >&2
    exit 1
}

# boolean reads a true/false action input, refusing anything else.
#
# Not a lenient match, deliberately: for both booleans here the wrong reading
# is the destructive one. `changed-only: yes` would publish an entire tree and
# `dry-run: yes` would perform a real forced publish, and GitHub passes inputs
# through as strings without normalising them, so a plausible typo has to fail
# rather than be guessed at.
boolean() {
    local name="$1" value="$2"
    case "$value" in
        true|false) printf '%s' "$value" ;;
        *) die "${name}: must be true or false, got '${value}'" ;;
    esac
}

# pathspecs prints the `files` input as NUL-separated git pathspec arguments.
#
# `set -f` is load-bearing. An unquoted expansion in a `for` list gets
# *pathname* expansion as well as word splitting, so without it the default
# `docs/**/*.md` is replaced by whatever `docs/*/*.md` matches on disk --
# globstar is off in a non-interactive shell, so `**` is just `*` -- and every
# top-level file is silently dropped. That is the exact failure the `:(glob)`
# prefix below exists to prevent, reintroduced one line earlier.
#
# The prefix itself: as a plain pathspec, `docs/**/*.md` matches
# `docs/sub/b.md` and misses `docs/a.md`, because plain `**` requires at least
# one intervening directory. Under `:(glob)`, `**` spans zero or more
# directories and `*` stops at `/` -- exactly the shell-glob semantics the
# input is written to look like.
#
# A pattern already starting with `:` passes through untouched, so a caller
# keeps their own magic: `:!docs/private/**` to exclude, for instance.
pathspecs() {
    local pat found=0
    set -f
    for pat in ${MARKFLUENCE_FILES}; do
        found=1
        case "$pat" in
            :*) printf '%s\0' "$pat" ;;
            *)  printf ':(glob)%s\0' "$pat" ;;
        esac
    done
    set +f
    [ "$found" = 1 ] || die "files: is empty; give it a pathspec such as 'docs/**/*.md'"
}

# base_ref prints the commit to diff against, or nothing when the event has a
# base that is legitimately absent and publishing everything is the intent.
#
# `since` wins when given. Then the event decides:
#
#   push          GITHUB_EVENT_BEFORE, which is all-zeros for a new branch or
#                 a force-push -- not an error, and the documented case where
#                 publishing everything is right.
#   pull_request  the PR's base sha.
#   anything else no range exists at all, and that is refused rather than
#                 treated as "publish everything". A schedule or a
#                 workflow_dispatch silently force-republishing an entire docs
#                 tree is the mass watcher-notification event the whole
#                 changed-only default exists to prevent.
base_ref() {
    local since="${MARKFLUENCE_SINCE:-}"
    if [ -n "$since" ]; then
        git rev-parse --verify --quiet "${since}^{commit}" >/dev/null ||
            die "since: '${since}' does not resolve to a commit in this checkout." \
                "A shallow clone is the usual cause: set fetch-depth: 0 on actions/checkout."
        printf '%s' "$since"
        return
    fi

    local event="${GITHUB_EVENT_NAME:-}" base=""
    case "$event" in
        push) base="${GITHUB_EVENT_BEFORE:-}" ;;
        pull_request|pull_request_target) base="${GITHUB_EVENT_PR_BASE_SHA:-}" ;;
        *)
            die "changed-only cannot work on a '${event:-unknown}' event: it has no commit range." \
                "Pass since: with a ref to diff against, or set changed-only: false if you really" \
                "do mean to publish everything -- note that Confluence emails every watcher on update."
            ;;
    esac

    # All-zeros, or absent on an event that should have had one. Publishing
    # everything is the documented reading for a new branch or a force-push.
    if [ -z "$base" ] || [ -z "${base//0/}" ]; then
        return
    fi
    require_full_clone
    git rev-parse --verify --quiet "${base}^{commit}" >/dev/null ||
        die "the base commit ${base} is not in this checkout." \
            "Set fetch-depth: 0 on actions/checkout -- both ends of the range have to be present."
    printf '%s' "$base"
}

# require_full_clone is checked only where a base is actually needed. A run
# that falls through to publishing everything works fine on a shallow clone,
# and failing it would be a refusal with no cause.
require_full_clone() {
    [ "$(git rev-parse --is-shallow-repository)" = false ] ||
        die "this is a shallow clone, so the commit range cannot be resolved." \
            "Set fetch-depth: 0 on actions/checkout."
}

# changed_files writes NUL-separated paths to $1.
#
# -z throughout, and NUL-separated: git only quotes non-ASCII and control
# characters, not spaces, so a newline-delimited list turns
# `docs/release notes.md` into two arguments.
#
# --diff-filter=ACMRT excludes deletions. A deleted file in the list fails the
# run, since markfluence cannot publish a file that is not there, and deleting
# a page is deliberately not something a publish does.
changed_files() {
    local out="$1" base head
    base="$(base_ref)"
    if [ -z "$base" ]; then
        echo "No base commit for this event (a new branch or a force-push reports none), so publishing everything."
        all_files "$out"
        return
    fi
    head="${GITHUB_SHA:-HEAD}"
    echo "Diffing ${base}..${head}"
    pathspecs | xargs -0 git diff -z --name-only --diff-filter=ACMRT "$base" "$head" -- > "$out"
}

# all_files writes every tracked file matching the pathspec to $1, via git
# rather than a shell glob so the pattern means the same thing in both paths.
all_files() {
    local out="$1"
    pathspecs | xargs -0 git ls-files -z -- > "$out"
}

# count_nul counts NUL-terminated records in $1.
count_nul() { tr -cd '\0' < "$1" | wc -c | tr -d ' '; }

main() {
    [ -n "${GITHUB_OUTPUT:-}" ] || die "GITHUB_OUTPUT is unset; this expects to run on a GitHub Actions runner"
    command -v markfluence >/dev/null 2>&1 ||
        die "markfluence is not on PATH. The publish action installs it itself, so this is a bug --" \
            "please report it: https://github.com/mozilla/markfluence-action/issues"

    local changed_only dry_run debug
    changed_only="$(boolean changed-only "${MARKFLUENCE_CHANGED_ONLY:-true}")"
    dry_run="$(boolean dry-run "${MARKFLUENCE_DRY_RUN:-false}")"
    debug="$(boolean debug "${MARKFLUENCE_DEBUG:-false}")"

    LIST="$(mktemp)"
    # Per-step, so two publish steps in one job cannot clobber each other's
    # results or have the first's `results-json` output name the second's data.
    local results="${RUNNER_TEMP:-/tmp}/markfluence-results-$$.json"

    if [ "$changed_only" = true ]; then
        changed_files "$LIST"
    else
        all_files "$LIST"
    fi

    local count
    count="$(count_nul "$LIST")"
    echo "count=${count}" >> "$GITHUB_OUTPUT"

    if [ "$count" -eq 0 ]; then
        # Not a failure, and not something to paper over by invoking
        # markfluence anyway: `update` with no FILE arguments is an error.
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

    # Read into an array rather than piping through xargs. Three reasons, all
    # of which bit: xargs splits on whitespace and honours quotes, so a path
    # with a space or an apostrophe breaks or aborts; xargs batches past
    # ARG_MAX, which would make markfluence emit several concatenated JSON
    # documents and corrupt $GITHUB_OUTPUT; and xargs remaps the exit status
    # (GNU reports 123 for a command that exited 1, BSD reports 1), so the
    # failure code depended on the runner's OS.
    #
    # `while read -d ''` rather than mapfile, which bash 3.2 does not have.
    local files=() f
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < "$LIST"

    echo "Publishing ${count} file(s):"
    printf '  %s\n' "${files[@]}"

    # --force is not configurable, and that is deliberate. CI is the
    # arrangement where the repository is the source of truth, so a Confluence
    # UI edit is drift rather than work. Without it, whether a page publishes
    # depends on a local action log that a fresh checkout does not have, and
    # files get reported `skipped` for a reason nobody in CI can act on. An
    # action that can be configured into that state is a trap.
    local args=(update --force --json)
    [ "$dry_run" = true ] && args+=(--dry-run)
    [ "$debug" = true ] && args+=(--debug)

    # The status is captured rather than allowed to kill the script: the JSON
    # is worth reporting either way, and the step should fail *after* the
    # outputs and summary are written.
    local status=0
    markfluence "${args[@]}" "${files[@]}" > "$results" || status=$?

    summarize "$results" "$status"
    return "$status"
}

# summarize turns the envelope into step outputs and a run summary.
#
# Reading the schema-locked --json rather than scraping human output, which is
# what that schema is for. jq is preinstalled on every GitHub-hosted runner.
summarize() {
    local results="$1" status="$2"
    # A single JSON *object*, not merely valid JSON: `jq -e .` accepts a
    # multi-document stream, and one output line per document would corrupt
    # $GITHUB_OUTPUT.
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$results" >/dev/null 2>&1; then
        # markfluence died before emitting a document -- bad credentials, say.
        # Its stderr is already in the log; do not hide that behind a jq error.
        echo "::error::markfluence exited ${status} without emitting a single JSON document; see the log above"
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
        jq -r '.results[]? | "- `\(.file // "?")` — \(if .ok then "ok" else "**failed**: \(.error // "unknown" | gsub("[\n\r]"; " ")) " end)"' \
            "$results"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

    # Newlines are collapsed **inside jq**, not afterwards in the shell. `jq -r`
    # unescapes them, so a two-line error emitted as a tab-separated record and
    # read back by a shell loop made the second line look like a new record --
    # producing `::error file=line two::`. A workflow command is one line by
    # definition, so the value has to be one line before it leaves jq.
    jq -r '.results[]? | select(.ok | not)
           | "::error file=\(.file // "")::\(.error // "failed" | gsub("[\n\r]+"; " "))"' \
        "$results"
}

main "$@"
