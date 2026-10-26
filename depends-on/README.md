# depends-on

Holds a pull request until what it depends on is merged. The action sets a
commit status (`depends-on`) on the pull request's head commit; make it a
required check in a ruleset and GitHub keeps the merge button disabled until
the status turns green.

## Declaring dependencies

One line per dependency in the pull request description. Lines inside fenced
code blocks do not count.

| Line | Met when |
|---|---|
| `Depends-on: #123` | pull request 123 of this repository is merged |
| `Depends-on: owner/repo#123` | that pull request on GitHub is merged |
| `Depends-on: https://github.com/owner/repo/pull/123` | the same |
| `Depends-on: owner/repo#123 released` | it is merged and its merge commit is in the latest release |
| `Depends-on: owner/repo#123 in <branch or tag>` | it is merged and its merge commit is in that branch or tag |
| `Depends-on: git <https url> <branch or tag>` | the ref exists in that git repository |
| `Depends-on: git <https url> <ref or commit> in <ref>` | that commit is reachable from `<ref>` |

The status is `success` when every dependency is met, `pending` while one is
not met yet, and `failure` when one cannot be met (closed without merge),
cannot be read, or is not understood. When all dependencies are met, the action comments on the
pull request once for that set of dependencies.

## Releasing the hold

- Edit the description: anyone with write access can remove or change a
  `Depends-on:` line, and the status follows at once.
- Bypass the ruleset: actors on its bypass list can merge regardless.
- Add the `depends-on: override` label: it counts when the person who added
  it has at least the `override-role` (default `maintain`); the status then
  names who released it. Removing the label restores the hold.

## Workflow

```yaml
name: "Pull request dependencies"

on:
  pull_request_target:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled, closed]
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch:

permissions: {}

concurrency:
  group: depends-on-${{ github.event.pull_request.number || 'all' }}
  cancel-in-progress: false

jobs:
  evaluate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      issues: read
    outputs:
      result: ${{ steps.evaluate.outputs.result }}
    steps:
      - id: evaluate
        uses: armbian/actions/depends-on@<commit sha>
        with:
          mode: evaluate

  apply:
    needs: evaluate
    runs-on: ubuntu-latest
    permissions:
      statuses: write
      pull-requests: write
    steps:
      - uses: armbian/actions/depends-on@<commit sha>
        with:
          mode: apply
          result: ${{ needs.evaluate.outputs.result }}
```

`pull_request_target` lets the check run for pull requests from forks; the
action never checks out their code, it reads only the description and labels
through the API. A closed pull request re-checks every open one, since others
may wait for it. The schedule catches changes in other repositories, which
send no event here. Pin the action to a commit: the workflow runs with write
access.

## Trust

The `evaluate` job reads the descriptions and contacts the dependencies with a
read-only token. Words from a description reach git and the API only as an
`https://` URL or a plain ref name; git speaks https only. The `apply` job
writes statuses and comments and reads no description, but it trusts the
decisions of `evaluate`: it only checks that each one names the head commit
of an open pull request and that a comment has the fixed shape. Never feed it
a `result` from an untrusted run.

The token must be able to read every repository named in a `Depends-on:`
line; the default token reads only its own repository and public ones.
