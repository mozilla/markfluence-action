# Releasing markfluence-action

**For maintainers.**

Summary: releases are driven by a git tag. You push the tag, CI verifies it and
moves the major tag, and you write the release notes.

> [!NOTE]
> **Untested.** `.github/workflows/release.yml` exists but no release has been
> cut yet, so nothing below has run end to end. Expect the first attempt to
> turn something up. Deleting this note is part of cutting `v1.0.0`.

## The org Actions allowlist: not a problem

Recorded because it looked like one, and the inference was wrong.

`mozilla` sets `allowed_actions: selected` with an org-wide allowlist, and
`mozilla/markfluence-action@*` is **not** on it. That reads like a blocker:
GitHub documents local `./` and `$/` references as always permitted and says
nothing about the `owner/repo@ref` form, and the allowlist names
`mozilla/tf-actions/matrixify@main` and `mozilla-it/deploy-actions/...`
explicitly — which looks like evidence that each mozilla-owned action has to
be listed.

**It is not.** Measured twice:

- **Same repository.** `smoke.yml`'s `at-main` job resolves
  `mozilla/markfluence-action@main` and passes.
- **Cross repository**, which is the case that actually matters.
  [`mozilla/markfluence-demo`](https://github.com/mozilla/markfluence-demo) is
  under the same `selected` policy, and a workflow there using
  `uses: mozilla/markfluence-action@main`
  [worked](https://github.com/mozilla/markfluence-demo/actions/runs/35644680004)
  — *Set up job* shows `Download action repository
  'mozilla/markfluence-action@main'` rather than a refusal, and the run went
  on to publish a page.

So mozilla-owned actions are permitted cross-repo without being listed, and
nothing needs adding. Whatever those explicit entries are for, they are not a
counterexample to what was measured. (#4, closed.)

Worth keeping in mind if this ever changes: a policy refusal surfaces during
*Set up job*, before any step runs, and names the action and the calling
repository. It does not look like anything else, so there is no need to guess.

## Versioning

We have two kinds of tag in markfluence-action with different properties and
different roles.

| tag | example | mutable? | what it is |
|---|---|---|---|
| release | `v1.2.3` | no | the exact code of one release |
| major | `v1` | **yes** | an alias, moved to the newest `v1.x.y` |

Most consumers pin to `v1` which is a mutable tag that we update to the latest
`v1.X.Y` tag. That is GitHub's own convention for actions — their guidance is
to *"move the major version tag (for example, v1) to point to the Git ref of
the current release"* — and it is why a `vX.Y.Z` tag gets a GitHub Release
(which makes it immutable) while `v1` deliberately does not.

**Nothing in markfluence-action requires semver the way markfluence does.**

Bump the **major** number when a consumer's workflow has to change: an input
renamed or removed, a default that flips, a runner no longer supported.

Bump the **minor** for a new input or output

Bump the **patch** for a fix.

An input gaining a new accepted value is a **minor** bump; an input whose
existing value now behaves differently is a **major** bump.

**A prerelease tag does not move the major tag.** `v1.0.0-rc.1` is checked and
released like anything else, but `v1` keeps pointing where it was — otherwise
every consumer pinned to `v1` would be running a release candidate.

## Versioning against markfluence

This repository's tags and markfluence's are **independent**. Fixes to the
action can be done independent of markfluence and markfluence releases are
independent of the action.

Users can specify which markfluence version to use with the `version:` input
and it accepts a markfluence release tag or `latest`. So:

- **Do not** bump this repository's version because markfluence released.
- **Do** bump it — a minor — when a change here requires a newer markfluence,
  and say so in the release notes. Nothing enforces a minimum version, so the
  notes are the only place that can be said.

## Where this runs

| | machine | what it does |
|---|---|---|
| landing the change | **your laptop** | a pull request, as usual |
| verifying the tag | **GitHub Actions** | `make check` against the tagged commit |
| moving `v1` | **GitHub Actions** | only after the checks pass |
| the GitHub Release | **your laptop** | notes, and the Marketplace checkbox |

Moving the major tag is CI's job because it can be automated. Writing the notes
is yours because CI cannot judge what mattered, and the Marketplace checkbox
needs 2FA and so cannot be automated at all.

## Steps

1. (laptop) **Land everything you want in the release.** `main` is protected: a
   pull request with all three matrix legs green. There is no way to push
   straight to it, and no bypass.

2. (laptop) **Smoke-test the actions as a consumer runs them.**

   ```sh
   gh workflow run smoke.yml
   gh run watch
   ```

   `.github/workflows/smoke.yml` needs no credentials. Two jobs run: `at-ref`
   uses the local paths (so it can test a branch), and `at-main` fetches the
   actions from this repository at `main` — the same remote path a consumer
   takes, into its own `_actions/` checkout. Since step 1 already required
   landing on `main`, `main` *is* the release candidate.

   Both install markfluence through `setup`, run the publish action with a
   pathspec matching nothing, and assert the outputs came back.

   **This is the step with no substitute.** `make check` exercises the scripts
   directly with a stubbed markfluence; it cannot exercise the composite
   actions at all — whether an input reaches its script, whether
   `$GITHUB_ACTION_PATH` resolves, whether an output propagates — because a
   composite action only exists inside a workflow.

   No credentials are needed for a reason worth knowing: `publish.sh` resolves
   the file list *before* invoking markfluence, so an empty selection
   exercises the whole composite and returns 0 having never called it.

   What it does **not** prove is that a publish works. That needs
   `CONFLUENCE_*` secrets in this repository and a fixture page, and
   `dry-run: true` does not get you out of it — `markfluence update` resolves
   credentials before it looks at the flag and exits 2 without them. Neither
   the secrets nor the fixture exist yet; see [Quality
   assurance](#quality-assurance).

3. (laptop) **Tag and push — one tag at a time.**

   ```sh
   git tag -a v1.2.3 -m 'v1.2.3'
   git push origin v1.2.3
   ```

   Not `git push origin --tags`, and not two tags in one push. `release.yml`
   serializes on a single concurrency group so two releases cannot race to
   move the major tag, and GitHub keeps at most one *pending* run per group —
   so a third queued run cancels the second, and a cancelled run renders
   neutral-grey rather than red. A release would go unchecked with nothing
   saying so.

4. (gha) **Watch the run.** `release.yml` runs `make check` against the tagged
   commit across all three runners, and then — only if that passes — moves `v1`
   to it.

   ```sh
   gh run watch
   ```

   If the checks fail, `v1` is untouched and consumers stay on the previous
   release.

5. (laptop) **Create the GitHub Release.**

   ```sh
   gh release create v1.2.3 --generate-notes --verify-tag

   # For a prerelease tag, --prerelease is REQUIRED. Without it an RC becomes
   # the repository's "Latest release" on the repo page and in the Marketplace
   # listing -- while the major tag correctly stays put, so the two disagree.
   gh release create v1.0.0-rc.1 --generate-notes --verify-tag --prerelease
   ```

   Then read what it generated and rewrite it. There are no build artifacts to
   attach — the release *is* the tag — so the notes are the entire deliverable,
   and the thing worth saying is what a consumer has to change, plus any
   markfluence version requirement.

   Newlines in a GitHub release body are line breaks, so do not hard-wrap
   paragraphs.

6. (laptop) **Verify what consumers get.** The same workflow, now including
   the job that uses the major tag:

   ```sh
   gh workflow run smoke.yml -f major=true
   gh run watch
   ```

   `at-major` is gated behind that flag because `uses:` against a tag that
   does not exist fails the job outright, and a skipped job never fetches its
   action — so it stays green before the first release and is opt-in
   afterwards. This is the only check that `v1` itself resolves to a working
   install, which is what every consumer pinned to it will get.

7. (laptop) **Fix the notes if they read badly.** `gh release edit v1.2.3
   --notes-file notes.md`. Nothing downstream reads the body; only humans do.

## Quality assurance

What is actually verified, and what is not, because the gap matters when
deciding how much a smoke test is worth.

`make check` exits non-zero on **any** zizmor finding, informational
included, so check its status rather than reading its output — a grep over the
log will happily show you a green-looking tail from a red run.

**`make check` covers, on all three supported runners:**

- shellcheck over every script, and actionlint over the workflows
- zizmor over the workflows *and* the action definitions
- `tests/install_test.sh` — the installer against **real** markfluence
  releases: platform mapping, checksum verify/tamper/missing, the refusals,
  and that the binary lands on `$GITHUB_PATH` executable
- `tests/publish_test.sh` — file selection and reporting against a stubbed
  markfluence: pathspec handling, the changed-only diff, every refusal, the
  outputs, the annotations

**`smoke.yml` covers**, manually, on dispatch — steps 2 and 6:

- the composite actions' wiring: inputs reaching their scripts,
  `$GITHUB_ACTION_PATH` resolving, outputs propagating. Nothing automated can,
  because a composite action only exists inside a workflow.
- three refs, because `uses:` takes a literal and so each needs its own job:
  `at-ref` (the local path, the only one that can test a branch), `at-main`
  (the remote fetch, which is what a consumer does), and `at-major` (`v1`
  itself, gated behind `-f major=true`).

**[`mozilla/markfluence-demo`](https://github.com/mozilla/markfluence-demo)
covers, end to end and for real:** a consumer repository publishing a page to
Confluence on a push, through the remote action fetch. Not automated from here
and not a gate on a release, but it is the one thing that exercises everything
at once —
[an example run](https://github.com/mozilla/markfluence-demo/actions/runs/35644680004)
resolved the push range, narrowed it to the single changed file, and published
it.

**Nothing covers:**
- **Publishing, from inside this repository.** `tests/publish_test.sh` stubs
  markfluence entirely. The demo above is a separate repository that nobody is
  obliged to keep working, so a release is not gated on it.
- **Whether `latest` resolves to a *working* markfluence.** The installer smoke
  test runs `--version`, not a publish.

One thing worth knowing before writing any smoke test: **`dry-run: true` does
not remove the credential requirement.** `markfluence update` resolves
credentials before it looks at the flag and exits 2 without them, so a dry run
writes nothing to Confluence but still has to reach it.

So: run step 2. It is the only thing standing between a green `make check` and
an action that does not work — and if a release changes how files are selected
or published, watch
[markfluence-demo](https://github.com/mozilla/markfluence-demo) afterwards,
since that is where it shows up for a real consumer.

## If a release goes wrong

**The checks failed.** `v1` was not moved and no Release exists, so consumers
are unaffected. Delete the tag, fix, re-tag:

```sh
git push --delete origin v1.2.3
git tag -d v1.2.3
```

**`v1` moved to something broken.** This is the one that reaches consumers.
Move it back to the last good release, then deal with the bad one:

```sh
git tag -f v1 v1.2.2^{commit}
git push -f origin refs/tags/v1
```

`^{commit}` is not optional here, for the same reason `release.yml` uses it:
the release tags are annotated, so without it `v1` points at the *tag object*
and git starts reporting "tag 'v1' is externally known as 'v1.2.2'". This is
the path run under pressure right after a bad release, which is exactly when
nobody checks.

**A Release is already published.** Deleting it does not un-ship anything —
anyone pinned to `v1.2.3` still resolves it, because `uses:` reads git refs
rather than releases. Prefer cutting `v1.2.4` over deleting a tag someone may
already have pinned. Before this repository has real consumers, re-cutting is
cheap; after, it is not.

## Publishing to the Marketplace

Not done yet, and optional. What it needs, verified against GitHub's docs:

- a **public** repository (this is one) with a **single `action.yml` at the
  root** (this has one). `setup/action.yml` works via `uses:` but can never be
  listed — one action per repository, root only.
- a **globally unique `name:`** in `action.yml`, not colliding with an
  existing listing, a GitHub user or org, or a Marketplace category.
- `branding:` — an icon and colour. Already set on the root action; absent from
  `setup/action.yml` on purpose, since it would never be shown.
- **The Marketplace Developer Agreement**, accepted by **the account that
  owns the repository** — which is `mozilla`, not you. GitHub disables the
  publish checkbox until that has happened, so like the Actions allowlist this
  is an **org-level** prerequisite a repo admin cannot satisfy. Unverified
  whether `mozilla` has accepted it; it is not exposed through the API.
- **A manual checkbox.** The flow starts from `action.yml` → *Draft a
  release* → *Publish this Action to the GitHub Marketplace*, then a primary
  category. It cannot be automated, so `gh release create` alone will never
  list it.

## References

- [pathspec](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec) — git's own glossary, for the `files` input
- [Releasing and maintaining actions](https://docs.github.com/actions/creating-actions/releasing-and-maintaining-actions) — where the moving major tag convention comes from
- [Immutable releases and tags](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/using-immutable-releases-and-tags-to-manage-your-actions-releases) — why `vX.Y.Z` gets a Release and `v1` does not
- [Publishing in the Marketplace](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-the-github-marketplace)
- [markfluence's own runbook](https://github.com/mozilla/markfluence/blob/main/docs/releasing.md) — a different shape, because it ships binaries
- [mozilla/markfluence-demo](https://github.com/mozilla/markfluence-demo) — a real consumer, and the only end-to-end publish there is
