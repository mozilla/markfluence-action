# markfluence-action

GitHub Actions for publishing markdown to Confluence with
[markfluence](https://github.com/mozilla/markfluence).

Two actions, because they answer different questions:

- **`mozilla/markfluence-action/setup`** installs the markfluence CLI and puts
  it on `PATH`, so a workflow can run any of its commands.
- **`mozilla/markfluence-action`** *(coming soon)* is the opinionated publish
  action that only publishes files that changed.

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

## Publishing

TBD

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
