# markfluence-action

GitHub Actions for publishing markdown to Confluence with
[markfluence](https://github.com/mozilla/markfluence).

Two actions, because they answer different questions:

- **`mozilla/markfluence-action/setup`** installs the markfluence CLI and puts
  it on `PATH`, so a workflow can run any of its commands.
- **`mozilla/markfluence-action`** is the opinionated publish action: it
  narrows a glob to the files git says actually changed, and publishes those.

This split facilitates a simple publish action step and also allows for other
use cases.

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
| the action code | the git ref in `uses:` | how the install works |
| the markfluence binary | the `version:` input | which markfluence you get |

```yaml
- uses: mozilla/markfluence-action/setup@v1   # <- this repository's tags
  with:
    version: v0.1.0                            # <- markfluence's release tags
```

They are separate tag namespaces in separate repositories, which is
deliberate: a fix to the installer ships without waiting for a markfluence
release, and a markfluence release needs no change here.

Pin the `uses:` ref to a tag or a commit SHA. Leaving `version` at `latest`
is a reasonable default — it resolves to markfluence's most recent published
release — but pin it too if you want a run to be reproducible.

**`version` takes a markfluence *release* tag, not a moving alias.**
`uses: …@v1` works because git resolves a moving tag; `version: v1` does not,
because there is no markfluence release by that name.

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
what to use instead. If you need either,
[open an issue](https://github.com/mozilla/markfluence-action/issues).

## Credentials

markfluence reads `CONFLUENCE_URL`, `CONFLUENCE_USERNAME` and
`CONFLUENCE_TOKEN` from the environment, plus `CONFLUENCE_CLOUD_ID` for a
scoped token. **The token is never an action input** — it stays a secret in
`env:`, which is also how the CLI is built: it refuses to accept a token as a
command-line flag at all.

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
| `files` | `docs/**/*.md` | Which markdown to publish, as a git pathspec. Space-separate several. |
| `changed-only` | `true` | Publish only what changed in the push range. Leave it on — see below. |
| `since` | *(none)* | Base ref to diff against, overriding the push event's. For a `workflow_dispatch`, which has no push range. |
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

### Why `changed-only` defaults to on

`paths:` on the trigger decides whether the *job* runs. It does not narrow the
glob. So publishing everything matching `files` on every merge means one typo
fix republishes the whole tree — and **Confluence emails every watcher on
update**, so a change to one page mails everyone watching any of two hundred.
That is the cost that gets a publishing bot switched off. It also fills page
history with identical versions and multiplies API calls against a rate limit
shared with everyone else on the instance.

Turn it off only if you mean it.

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

## License

[Mozilla Public License 2.0](LICENSE), matching markfluence.
