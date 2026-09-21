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

# new_repo builds a git repository with two commits: docs/a.md, docs/sub/b.md
# and docs/notes.txt in the first, a change to docs/a.md only in the second.
# Prints its path.
#
# The **subdirectory is load-bearing**. An earlier fixture had only top-level
# files, which is exactly why a glob bug hid: with nothing for `docs/*/*.md`
# to match, bash left the pattern intact and the pathspec worked by accident.
# The .txt is here so a too-broad pathspec shows up as a wrong count rather
# than passing.
new_repo() {
    local d
    d="$(mktemp -d)"
    (
        cd "$d" || exit 1
        git init -q
        git config user.email t@example.com
        git config user.name test
        mkdir -p docs/sub
        echo one > docs/a.md
        echo two > docs/sub/b.md
        echo notes > docs/notes.txt
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
        # Set outright, NOT defaulted from the ambient value. These tests run
        # inside GitHub Actions, where GITHUB_EVENT_NAME is already `push` or
        # `pull_request` -- so `${GITHUB_EVENT_NAME:-push}` inherited the
        # runner's `pull_request`, sent base_ref down the PR branch looking for
        # a base sha that was never set, and every case fell through to
        # "publish everything". Green locally, red on all three legs.
        #
        # A caller's `env "$@"` below still overrides these, which is how the
        # schedule and pull_request cases set their own.
        export GITHUB_EVENT_NAME=push
        export GITHUB_EVENT_BEFORE=
        export GITHUB_EVENT_PR_BASE_SHA=
        export MARKFLUENCE_CHANGED_ONLY=true
        export MARKFLUENCE_DRY_RUN=false
        export MARKFLUENCE_DEBUG=false
        export MARKFLUENCE_SINCE=
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
contains 'results-json points at a file' "$(out "$r" 'results-json')" 'markfluence-results-'
rm -rf "$r"

# --- changed-only=false takes everything matching the glob ----------------
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false >/dev/null
# Two .md files across two directory levels, and NOT docs/notes.txt. This is
# the assertion that catches both glob bugs: pathname expansion in the `for`
# list, and a plain pathspec whose `**` skips top-level files.
check 'the glob spans both levels and excludes non-markdown' "$(out "$r" count)" 2
contains 'the top-level file is included' "$(cat "$r/argv")" 'docs/a.md'
contains 'the nested file is included' "$(cat "$r/argv")" 'docs/sub/b.md'
case "$(cat "$r/argv")" in
    *notes.txt*) printf 'FAIL non-markdown is excluded\n'; fail=$((fail + 1)) ;;
    *) printf 'ok   non-markdown is excluded\n'; pass=$((pass + 1)) ;;
esac
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
# Asserted as non-zero rather than as 1. It really is 1 now that markfluence
# is invoked directly, but routing it through xargs used to remap it -- GNU
# reports 123 for a command that exited 1, BSD reports 1 -- so a hardcoded 1
# passed locally and would have failed on the Linux legs of the matrix.
check 'a failing publish exits nonzero' "$([ "$status" -ne 0 ] && echo nonzero || echo zero)" nonzero
contains 'a failing file becomes an annotation' "$o" '::error file=docs/a.md::page 1 not found'
check 'failed is read from the envelope' "$(out "$r" failed)" 1
rm -rf "$r"

# --- markfluence dying without JSON is reported, not hidden ---------------
r="$(new_repo)"
mkdir -p "$r/bin"
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 2\n' > "$r/bin/markfluence"
chmod +x "$r/bin/markfluence"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false)"
contains 'no-JSON exit is named' "$o" 'without emitting a single JSON document'
rm -rf "$r"

# --- a path with a space survives ------------------------------------------
# git only quotes non-ASCII and control characters, not spaces, so a
# newline-delimited list would hand markfluence two arguments here.
r="$(new_repo)"; fake_markfluence "$r"
(
    cd "$r" || exit 1
    echo spaced > "docs/release notes.md"
    git add -A && git commit -qm spaced
)
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false >/dev/null
check 'a path with a space is one file' "$(out "$r" count)" 3
contains 'a path with a space reaches the CLI intact' "$(cat "$r/argv")" 'docs/release notes.md'
rm -rf "$r"

# --- a path with an apostrophe survives ------------------------------------
# This is what made xargs abort outright with "unmatched single quote".
r="$(new_repo)"; fake_markfluence "$r"
(
    cd "$r" || exit 1
    echo apos > "docs/don't.md"
    git add -A && git commit -qm apos
)
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false >/dev/null
contains 'a path with an apostrophe reaches the CLI intact' "$(cat "$r/argv")" "docs/don't.md"
rm -rf "$r"

# --- an unrecognised boolean is refused, not guessed at --------------------
# For both of these the wrong reading is the destructive one: publishing a
# whole tree, or performing a real forced publish.
r="$(new_repo)"; fake_markfluence "$r"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=yes)"
contains 'changed-only: yes is refused' "$o" 'must be true or false'
check 'changed-only: yes never calls markfluence' "$([ -f "$r/argv" ] && echo called || echo not-called)" not-called
rm -rf "$r"

r="$(new_repo)"; fake_markfluence "$r"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false MARKFLUENCE_DRY_RUN=yes)"
contains 'dry-run: yes is refused' "$o" 'must be true or false'
rm -rf "$r"

# --- a whitespace-only files input is refused ------------------------------
# It passes a -n check, and with no pathspec GNU xargs would run git ls-files
# over the whole repository while BSD would skip it -- a runner-dependent
# divergence between "publish everything" and "publish nothing".
r="$(new_repo)"; fake_markfluence "$r"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false 'MARKFLUENCE_FILES=   ')"
contains 'a whitespace-only files input is refused' "$o" 'files: is empty'
rm -rf "$r"

# --- an event with no commit range is refused -----------------------------
# Not read as "publish everything": a schedule force-republishing a docs tree
# is the mass watcher-notification event changed-only exists to prevent.
r="$(new_repo)"; fake_markfluence "$r"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true GITHUB_EVENT_NAME=schedule)"
contains 'an event with no range is refused' "$o" 'has no commit range'
contains 'the refusal points at since:' "$o" 'since:'
check 'an event with no range never publishes' "$([ -f "$r/argv" ] && echo called || echo not-called)" not-called
rm -rf "$r"

# --- a pull_request uses its base sha -------------------------------------
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=true GITHUB_EVENT_NAME=pull_request \
    "GITHUB_EVENT_PR_BASE_SHA=$(cd "$r" && git rev-parse HEAD~1)" >/dev/null
check 'a pull_request diffs against its base' "$(out "$r" count)" 1
rm -rf "$r"

# --- changed-only=false works on a shallow clone --------------------------
# The shallow guard belongs only where a base is actually needed; a run that
# publishes everything never resolves a range.
r="$(new_repo)"; fake_markfluence "$r"
shallow="$(mktemp -d)"
git clone -q --depth 1 "file://$r" "$shallow/repo" 2>/dev/null
cp -R "$r/bin" "$shallow/repo/bin"
run_publish "$shallow/repo" MARKFLUENCE_CHANGED_ONLY=false >/dev/null
check 'a shallow clone can still publish everything' "$(out "$shallow/repo" count)" 2
rm -rf "$r" "$shallow"

# --- a shallow clone IS refused when a base is needed ---------------------
r="$(new_repo)"; fake_markfluence "$r"
shallow="$(mktemp -d)"
git clone -q --depth 1 "file://$r" "$shallow/repo" 2>/dev/null
cp -R "$r/bin" "$shallow/repo/bin"
o="$(run_publish "$shallow/repo" MARKFLUENCE_CHANGED_ONLY=true \
    GITHUB_EVENT_BEFORE=1111111111111111111111111111111111111111)"
contains 'a shallow clone is refused when a base is needed' "$o" 'shallow clone'
rm -rf "$r" "$shallow"

# --- several JSON documents are refused, not half-read --------------------
# xargs used to batch past ARG_MAX, which made markfluence emit concatenated
# envelopes; one output line per document would corrupt $GITHUB_OUTPUT.
r="$(new_repo)"
mkdir -p "$r/bin"
cat > "$r/bin/markfluence" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_FILE"
echo '{"summary":{"total":1,"succeeded":1,"failed":0,"skipped":0},"results":[]}'
echo '{"summary":{"total":1,"succeeded":1,"failed":0,"skipped":0},"results":[]}'
STUB
chmod +x "$r/bin/markfluence"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false)"
contains 'a multi-document stream is refused' "$o" 'without emitting a single JSON document'
check 'a multi-document stream leaves published at 0' "$(out "$r" published)" 0
rm -rf "$r"

# --- a multi-line error becomes one annotation line ------------------------
r="$(new_repo)"
mkdir -p "$r/bin"
cat > "$r/bin/markfluence" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_FILE"
cat <<'JSON'
{"summary":{"total":1,"succeeded":0,"failed":1,"skipped":0},
 "results":[{"file":"docs/a.md","ok":false,"error":"line one\nline two"}]}
JSON
exit 1
STUB
chmod +x "$r/bin/markfluence"
o="$(run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false)"
contains 'a multi-line error is collapsed' "$o" '::error file=docs/a.md::line one line two'
rm -rf "$r"

# --- the multi-line form of `files` -----------------------------------------
# A YAML block scalar arrives as a newline-separated string. It works without
# any special handling because bash's default IFS includes newline, and the
# README documents it, so it needs a test to stay true.
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false 'MARKFLUENCE_FILES=docs/a.md
docs/sub/b.md' >/dev/null
check 'a newline-separated files input selects both' "$(out "$r" count)" 2
contains 'the first line is honoured' "$(cat "$r/argv")" 'docs/a.md'
contains 'the second line is honoured' "$(cat "$r/argv")" 'docs/sub/b.md'
rm -rf "$r"

# --- exclusion magic in the multi-line form --------------------------------
r="$(new_repo)"; fake_markfluence "$r"
run_publish "$r" MARKFLUENCE_CHANGED_ONLY=false 'MARKFLUENCE_FILES=docs/**/*.md
:!docs/sub/**' >/dev/null
check 'exclusion on its own line still excludes' "$(out "$r" count)" 1
contains 'the kept file is the top-level one' "$(cat "$r/argv")" 'docs/a.md'
rm -rf "$r"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
