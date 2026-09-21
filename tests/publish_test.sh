#!/usr/bin/env bash
#
# Exercise publish/publish.sh's file selection and reporting.
#
# Unlike tests/install_test.sh this needs no network and no credentials: it
# builds a throwaway git repository and puts a fake `markfluence` on PATH that
# records its arguments and emits a canned --json envelope. What is under test
# is which files get chosen and what gets reported -- the publishing itself is
# markfluence's own test suite's job, and an end-to-end run against a live
# Confluence instance is a separate workflow.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT="${ROOT}/publish/publish.sh"

pass=0
fail=0

check() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   %s\n' "$name"
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n     got:  %s\n     want: %s\n' "$name" "$got" "$want"
        fail=$((fail + 1))
    fi
}

contains() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*)
            printf 'ok   %s\n' "$name"
            pass=$((pass + 1)) ;;
        *)
            printf 'FAIL %s\n     expected to contain: %s\n     got: %s\n' "$name" "$needle" "$haystack"
            fail=$((fail + 1)) ;;
    esac
}

# new_repo builds a git repository with two commits: docs/a.md and docs/b.md
# in the first, a change to docs/a.md only in the second. Prints its path.
new_repo() {
    local d
    d="$(mktemp -d)"
    (
        cd "$d" || exit 1
        git init -q
        git config user.email t@example.com
        git config user.name test
        mkdir -p docs
        echo one > docs/a.md
        echo two > docs/b.md
        git add -A && git commit -qm first
        echo one-changed > docs/a.md
        git add -A && git commit -qm second
    )
    printf '%s' "$d"
}

# fake_markfluence installs a stub on PATH in $1/bin that records its argv to
# $1/argv and prints a valid update envelope.
fake_markfluence() {
    local dir="$1"
    mkdir -p "$dir/bin"
    cat > "$dir/bin/markfluence" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_FILE"
cat <<'JSON'
{"schema_version":"1.0.0","markfluence_version":"test","command":"update",
 "roots":[],"warnings":[],
 "results":[{"file":"docs/a.md","ok":true}],
 "summary":{"total":1,"succeeded":1,"failed":0,"skipped":0}}
JSON
STUB
    chmod +x "$dir/bin/markfluence"
}

# run_publish runs the script in a repo with the given environment. Prints
# combined output; the step outputs land in $OUT_FILE for the caller to read.
run_publish() {
    local repo="$1"; shift
    (
        cd "$repo" || exit 1
        export PATH="${repo}/bin:$PATH"
        export RUNNER_TEMP="${repo}/tmp"
        export GITHUB_OUTPUT="${repo}/step_output"
        export GITHUB_STEP_SUMMARY="${repo}/step_summary"
        export ARGV_FILE="${repo}/argv"
        mkdir -p "$RUNNER_TEMP"
        : > "$GITHUB_OUTPUT"
        : > "$GITHUB_STEP_SUMMARY"
        export MARKFLUENCE_FILES='docs/**/*.md'
        export GITHUB_SHA
        GITHUB_SHA="$(git rev-parse HEAD)"
        env "$@" bash "$SCRIPT" 2>&1
    )
}

# out reads one step output by key from the repo's captured GITHUB_OUTPUT.
out() { sed -n "s/^$2=//p" "$1/step_output" | tail -1; }

# --- changed-only picks just the file that changed -------------------------
r="$(new_repo)"; fake_markfluence "$r"
before="$(cd "$r" && git rev-parse HEAD~1)"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true "GITHUB_EVENT_BEFORE=$before" >/dev/null
check 'changed-only selects one file' "$(out "$r" count)" 1
contains 'changed-only publishes the changed file' "$(cat "$r/argv")" 'docs/a.md'
case "$(cat "$r/argv")" in
    *docs/b.md*) printf 'FAIL changed-only left the unchanged file alone\n'; fail=$((fail + 1)) ;;
    *) printf 'ok   changed-only left the unchanged file alone\n'; pass=$((pass + 1)) ;;
esac
contains '--force is always passed' "$(cat "$r/argv")" '--force'
contains '--json is always passed' "$(cat "$r/argv")" '--json'
check 'published is read from the envelope' "$(out "$r" published)" 1
contains 'results-json points at a file' "$(out "$r" 'results-json')" 'markfluence-results.json'
rm -rf "$r"

# --- changed-only=false takes everything matching the glob ----------------
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false >/dev/null
check 'changed-only=false selects both files' "$(out "$r" count)" 2
rm -rf "$r"

# --- nothing changed: skip rather than invoke markfluence -----------------
# `update` with no FILE arguments is an error, so an empty diff must not reach
# it. HEAD..HEAD is the empty range.
r="$(new_repo)"; fake_markfluence "$r"
head="$(cd "$r" && git rev-parse HEAD)"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true "GITHUB_EVENT_BEFORE=$head")"
check 'an empty diff selects nothing' "$(out "$r" count)" 0
contains 'an empty diff says so' "$o" 'nothing to publish'
check 'an empty diff never calls markfluence' "$([ -f "$r/argv" ] && echo called || echo not-called)" not-called
rm -rf "$r"

# --- an all-zero base means publish everything, not fail ------------------
# A new branch or a force-push reports an all-zero sha.
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true \
    GITHUB_EVENT_BEFORE=0000000000000000000000000000000000000000 >/dev/null
check 'an all-zero base publishes everything' "$(out "$r" count)" 2
rm -rf "$r"

# --- since: overrides the event's base ------------------------------------
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true "MARKFLUENCE_SINCE=$(cd "$r" && git rev-parse HEAD~1)" >/dev/null
check 'since: narrows to one file' "$(out "$r" count)" 1
rm -rf "$r"

# --- a bad since: is named --------------------------------------------------
r="$(new_repo)"; fake_markfluence "$r"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true MARKFLUENCE_SINCE=nope-not-a-ref)"
contains 'a bad since: names itself' "$o" "does not resolve"
rm -rf "$r"

# --- dry-run and debug reach the CLI --------------------------------------
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false MARKFLUENCE_DRY_RUN=true MARKFLUENCE_DEBUG=true >/dev/null
contains 'dry-run reaches the CLI' "$(cat "$r/argv")" '--dry-run'
contains 'debug reaches the CLI' "$(cat "$r/argv")" '--debug'
rm -rf "$r"

# --- a failing file is surfaced as an annotation and a nonzero exit --------
r="$(new_repo)"
mkdir -p "$r/bin"
cat > "$r/bin/markfluence" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_FILE"
cat <<'JSON'
{"schema_version":"1.0.0","markfluence_version":"test","command":"update",
 "roots":[],"warnings":[],
 "results":[{"file":"docs/a.md","ok":false,"error":"page 1 not found"}],
 "summary":{"total":1,"succeeded":0,"failed":1,"skipped":0}}
JSON
exit 1
STUB
chmod +x "$r/bin/markfluence"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false)"
status=$?
check 'a failing publish exits nonzero' "$status" 1
contains 'a failing file becomes an annotation' "$o" '::error file=docs/a.md::page 1 not found'
check 'failed is read from the envelope' "$(out "$r" failed)" 1
rm -rf "$r"

# --- markfluence dying without JSON is reported, not hidden ---------------
r="$(new_repo)"
mkdir -p "$r/bin"
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 2\n' > "$r/bin/markfluence"
chmod +x "$r/bin/markfluence"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false)"
contains 'no-JSON exit is named' "$o" 'without emitting JSON'
rm -rf "$r"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
