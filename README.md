# markfluence-action

GitHub Actions for publishing markdown to Confluence with
[markfluence](https://github.com/mozilla/markfluence).

Two actions, because they answer different questions:

- **`mozilla/markfluence-action/setup`** installs the markfluence CLI and puts
  it on `PATH`, so a workflow can run any of its commands.
- **`mozilla/markfluence-action`** is the opinionated publish action: it
  narrows a glob to the files git says actually changed, and publishes those.

This split facilitates a convenient publish action step and also allows for
other use cases.

> [!IMPORTANT]
> **Mozilla repositories:** the org restricts which actions may run, and
> `mozilla/markfluence-action` is not yet on the allowlist — so `uses:` will
> be refused until it is added. See
> [docs/releasing.md](docs/releasing.md#prerequisite-the-org-actions-allowlist).

## setup

```yaml
- uses: mozilla/markfluence-action/setup@v1
  with:
    version: v0.1.0        # optional; defaults to "latest"

- run: markfluence check docs/**/*.md
```

| input | default | description |
|---|---|---|
| `version` | `latest` | Release tag to install, such as `v0.1.0`. |

| output | description |
|---|---|
| `version` | The tag actually installed, resolved if you asked for `latest`. |

It downloads the release archive, verifies it against the release's
`checksums.txt`, extracts the binary, and runs `markfluence --version` as a
smoke test — so a bad asset fails in this step rather than three steps later
in the middle of a publish.

## Pinning

There are **two independent things to pin**, and they come from different
places:

| | pinned by | decides |
|---|---|---|
| the action code | the git ref in `uses:` | how the action works |
| the markfluence binary | the `version:` input | which markfluence you get |

```yaml
- uses: mozilla/markfluence-action/setup@v1   # <- this repository's tags
  with:
    version: v0.1.0                            # <- markfluence's release tags
```

This allows us to ship fixes to the GitHub action separate from markfluence
releases.

**`uses` takes a markfluence-action tag or commit SHA.** The tag can be a
specific version or the moving `v1` major version tag.

**`version` takes a markfluence release tag or `latest`.** Leaving `version` at
`latest` is a reasonable default — it resolves to markfluence's most recent
published release — but pin it if you want a run to be reproducible.

## Supported runners

| runner | supported |
|---|---|
| `ubuntu-latest` | ✅ |
| `ubuntu-24.04-arm` | ✅ |
| `macos-latest` | ✅ |
| `macos-13` (Intel) | ❌ |
| `windows-latest` | ❌ |

markfluence publishes no Windows build, and no Intel macOS build since
[macOS 26 Tahoe became Apple's last Intel release](https://support.apple.com/en-us/122867).
Both fail with a named error rather than a download 404, so the message says
what to use instead.

## Credentials

markfluence reads `CONFLUENCE_URL` (secret), `CONFLUENCE_USERNAME` (secret) and
`CONFLUENCE_TOKEN` (secret)from the environment, plus `CONFLUENCE_CLOUD_ID`
(not a secret) for a scoped token.

Example:

```yaml
- uses: mozilla/markfluence-action/setup@v1
- run: markfluence space-info ENG
  env:
    CONFLUENCE_URL: ${{ secrets.CONFLUENCE_URL }}
    CONFLUENCE_USERNAME: ${{ secrets.CONFLUENCE_USERNAME }}
    CONFLUENCE_TOKEN: ${{ secrets.CONFLUENCE_TOKEN }}
    # A variable, not a secret: the cloud ID is not sensitive.
    CONFLUENCE_CLOUD_ID: ${{ vars.CONFLUENCE_CLOUD_ID }}
```

## publish

This publishes every markdown file that changed, matches `files` argument, and
names a Confluence page — via a page_id in its frontmatter or an entry in
`markfluence.yaml`. A file that names no page is skipped, not failed, so a
repository that has markdown files that aren't intended to be published to
Confluence does the right hings and doesn't cause errors.

```yaml
name: Publish docs to Confluence

on:
  push:
    branches: [main]
    paths: ['docs/**.md']

# Don't let two publishes race on the same pages.
concurrency:
  group: confluence-publish
  cancel-in-progress: false

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0        # both ends of the push range have to be present

      - uses: mozilla/markfluence-action@v1
        with:
          files: 'docs/**/*.md'
        env:
          CONFLUENCE_URL: ${{ secrets.CONFLUENCE_URL }}
          CONFLUENCE_USERNAME: ${{ secrets.CONFLUENCE_USERNAME }}
          CONFLUENCE_TOKEN: ${{ secrets.CONFLUENCE_TOKEN }}
          CONFLUENCE_CLOUD_ID: ${{ vars.CONFLUENCE_CLOUD_ID }}
```

**`fetch-depth: 0` is required** and the action cannot set it for you. Without
it the push range cannot be resolved; the action detects the shallow clone and
says so by name rather than failing on a confusing `bad object`.

| input | default | description |
|---|---|---|
| `files` | `docs/**/*.md` | Which markdown to publish, as one or more git pathspecs. See [How `files` works](#how-files-works). |
| `changed-only` | `true` | Publish only what changed. Leave it on — see below. Works on `push` and `pull_request`; any other event has no commit range and the run fails rather than publishing everything. |
| `since` | *(none)* | Base ref to diff against, overriding the event's. Required on an event with no range, such as `workflow_dispatch` or `schedule`. |
| `dry-run` | `false` | Preview without writing to Confluence. |
| `debug` | `false` | Log every retry decision with the rate-limit headers. |
| `version` | `latest` | markfluence release to install. |

| output | description |
|---|---|
| `count` | Files selected for publishing. |
| `published` | Pages published. |
| `skipped` | Files skipped because nothing claims them. |
| `failed` | Files that failed. |
| `results-json` | Path to markfluence's `--json` envelope, for a later step. Empty when nothing ran. |

### How `files` works

`files` takes one or more **git pathspecs**, separated by spaces. They are not
shell globs, but they behave like them: each pattern gets git's `:(glob)`
magic, so `**` spans zero or more directories and `*` stops at `/`.

| value | matches |
|---|---|
| `docs/**/*.md` | every `.md` under `docs/`, at any depth including the top level |
| `docs/*.md` | only the top level of `docs/` |
| `**/*.md` | every `.md` in the repository |
| `docs/**/*.md runbooks/**/*.md` | both trees |
| `docs/a.md docs/b.md` | exactly those two files, and nothing else |
| `docs/**/*.md :!docs/private/**` | the first, minus the second |

A pattern starting with `:` is passed through untouched, which is what makes
that last row work: `:!` is git's exclusion magic, and any other pathspec
magic (`:(icase)`, `:(top)`) works the same way.

Three limits worth knowing:

- **A pattern cannot contain a space**, because the input is split on
  whitespace. `'my docs/*.md'` becomes two patterns and matches nothing
  useful, and the multi-line form does not change that — splitting happens
  within a line as well as between lines. Matched *paths* may contain spaces
  (`docs/release notes.md` publishes fine); it is only the pattern that
  cannot.
- **Value must be a scalar**, because GitHub requires every `with:` value to be
  a scalar, so `files:` followed by `- docs/a.md` is rejected before this
  action sees it.
- **Only tracked files match.** git does not see an untracked file, so a
  brand-new markdown file that has not been committed is not published. That
  is never an issue in CI, where the checkout is clean, but it will surprise
  you running the action locally.

Patterns can be on one line:

```yaml
with:
  files: docs/**/*.md runbooks/**/*.md :!docs/private/**
```

Or multiple lines with `|`:

```yaml
with:
  files: |
    docs/**/*.md
    runbooks/**/*.md
    :!docs/private/**
```

Paths are relative to the repository root.

References:

* [git pathspec](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec)
* [with: workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepswith)

### Why `changed-only` defaults to on

`paths:` on the trigger decides whether the *job* runs but doesn't affect the
files that get published.

`files` specifies all the possible files in the repository that could be
published after a merge.

`changed-only` ensures that only the files listed in `files` that actually
changed are published. Otherwise every merge republishes the whole tree to
Confluence creating a new version of the page and emailing every watcher.
**Turn it off only if you mean it.**

**An event with no commit range fails rather than guessing.** A `schedule` or
a `workflow_dispatch` has no base to diff against, and treating that as
"publish everything" would silently produce exactly the mass notification
described above. Pass `since:` on those events, or set `changed-only: false`
if you really do mean the whole tree.

### `--force` is always on, and is not an input

CI is the arrangement where the repository is the source of truth, so an edit
made in the Confluence UI is drift rather than work, and the next publish is
meant to overwrite it. Without `--force`, whether a page publishes depends on
a local action log that a fresh checkout does not have, so files get reported
`skipped` for a reason nobody in CI can act on. An action that can be
configured into that state is a trap, so this one cannot be.

### What it does not do

**It never creates pages.** `create` writes a new `page_id` back into your
repository, which a workflow has no good way to commit. Create locally, commit
the id, and let CI update from then on.

**It never deletes.** The file list excludes deletions
(`--diff-filter=ACMRT`), so removing a markdown file leaves its page alone.

## Developing

```sh
make            # list the rules
make check      # everything CI runs, in CI's order
```

CI runs `make check` and nothing else, so what is checked here and what is
checked on a runner cannot drift. Tool *versions* still can — see the note at
the top of the `Makefile`. You need `shellcheck`, `actionlint` and `zizmor`
on your `PATH`.

`make test` exercises `setup/install.sh` against real markfluence releases,
so it needs network access. That is deliberate: the thing under test is a
downloader, and a test that stubbed the download would only prove the stub
works.

## Releasing

For maintainers: [docs/releasing.md](docs/releasing.md).

## License

[Mozilla Public License 2.0](LICENSE), matching markfluence.
