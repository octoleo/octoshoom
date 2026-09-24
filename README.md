<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
OctoShoom - Automated Joomla Update Server Hash Injector
</h2>

![Test](https://github.com/octoleo/octoshoom/actions/workflows/test.yml/badge.svg)

Written by Llewellyn van der Merwe (@llewellynvdm)

With this script, we can automatically calculate **SHA-512 hashes** for every ZIP file listed in one or more Joomla update server XML files, inject those `<sha512>` tags into the XML, and push the changes back to their repositories — all from a single JSON configuration file, with environment variable support.

It runs as a **GitHub Action** (chained after [octoleo/git-user](https://github.com/octoleo/git-user)) or as a plain command line tool.

Linted by [#ShellCheck](https://github.com/koalaman/shellcheck)

> Program currently supports **Ubuntu/Debian** environments with **SSH-based Git access** (Gitea, GitHub, or GitLab).
> If you'd like to run this on other systems, please open an issue.

---

# GitHub Action

OctoShoom ships an `action.yml`, so it can be used directly in a workflow. It only does one thing: clone the update server repositories over SSH, inject the hashes, commit and push. It does **not** set up Git for you — run [octoleo/git-user](https://github.com/octoleo/git-user) first; that action configures the Git identity, GPG signing, the SSH key and the known hosts, and OctoShoom simply uses them.

## Quick start

```yaml
name: Update Server Hashes

on:
  workflow_dispatch:
  schedule:
    - cron: '0 3 * * *'

jobs:
  hashes:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Git User
        uses: octoleo/git-user@v2
        with:
          gpg-key: ${{ secrets.GPG_KEY }}
          gpg-user: ${{ secrets.GPG_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          ssh-pub: ${{ secrets.SSH_PUB }}
          git-user: ${{ secrets.GIT_USER }}
          git-email: ${{ secrets.GIT_EMAIL }}

      - name: Inject SHA512 hashes
        uses: octoleo/octoshoom@master
        with:
          config: .github/update_servers.json
```

> Pin `octoleo/octoshoom@master` to a release tag or a commit SHA once you have one.

The configuration file is the same JSON file the command line tool uses (see [JSON Configuration File](#json-configuration-file)). It can also be passed inline with `config-json`, which makes it easy for an earlier step to generate it:

```yaml
      - name: Inject SHA512 hashes
        uses: octoleo/octoshoom@master
        with:
          config-json: |
            {
              "update_servers": [
                { "owner": "joomengine", "repo": "pkg-component-builder", "branch": "main", "path": "component_updates.xml" }
              ]
            }
```

## Another Git server (Gitea, GitLab, ...)

The `git-url` input must match the `ssh-host` given to git-user, so the SSH key and known hosts apply to the same server:

```yaml
      - name: Setup Git User
        uses: octoleo/git-user@v2
        with:
          gpg-key: ${{ secrets.GPG_KEY }}
          gpg-user: ${{ secrets.GPG_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          ssh-pub: ${{ secrets.SSH_PUB }}
          git-user: ${{ secrets.GIT_USER }}
          git-email: ${{ secrets.GIT_EMAIL }}
          ssh-host: git.vdm.dev

      - name: Inject SHA512 hashes
        uses: octoleo/octoshoom@master
        with:
          config: .github/update_servers.json
          git-url: git.vdm.dev
```

## Chaining with other workflows

Every run exposes what happened as outputs, so later steps (or jobs) can react to it:

```yaml
      - name: Inject SHA512 hashes
        id: octoshoom
        uses: octoleo/octoshoom@master
        with:
          config: .github/update_servers.json

      - name: Notify
        if: steps.octoshoom.outputs.changed == 'true'
        run: |
          echo "Updated ${{ steps.octoshoom.outputs.updated-count }} update server file(s):"
          echo '${{ steps.octoshoom.outputs.updated }}' | jq -r '.[]'
```

A **dry run** calculates the hashes and prints the diff without committing or pushing, which is handy for pull request checks:

```yaml
      - name: Check update server hashes
        id: check
        uses: octoleo/octoshoom@master
        with:
          config: .github/update_servers.json
          dry-run: 'true'

      - name: Fail when hashes are stale
        if: steps.check.outputs.changed == 'true'
        run: |
          echo "::error::The update server hashes are out of date."
          exit 1
```

The action exits with code `1` when any target fails (a branch or XML file that does not exist, a package that cannot be downloaded, a failed push). All other targets are still processed and the failures are listed in the `failed` output and in the job summary. Use `continue-on-error: true` on the step if a failure should not stop the workflow.

## Inputs

| Input                  | Required | Default                                  | Description                                                                                                                     |
|------------------------|----------|------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `config`               | No*      |                                          | Path to the JSON configuration file (relative to the workspace, or absolute)                                                    |
| `config-json`          | No*      |                                          | Inline JSON configuration, used when `config` is empty                                                                          |
| `git-url`              | No       | `github.com`                             | SSH host of the Git server holding the update server repositories. Must match the `ssh-host` given to git-user                  |
| `git-user`             | No       |                                          | Git author name. Leave empty to use the identity configured by git-user                                                         |
| `git-email`            | No       |                                          | Git author email. Leave empty to use the identity configured by git-user                                                        |
| `gpg-sign`             | No       |                                          | `true` or `false` to force commit signing on or off. Leave empty to inherit the global git configuration                        |
| `signing-key`          | No       |                                          | GPG key ID to sign with. Leave empty to inherit the global git configuration                                                    |
| `commit-message`       | No       | `chore: add sha512 hashes via OctoShoom` | Commit message for the hash updates                                                                                             |
| `env-file`             | No       |                                          | Optional `.env` file with `GIT_URL`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_GPG_SIGN`, `GIT_SIGNING_KEY`. Inputs win over it |
| `dry-run`              | No       | `false`                                  | Calculate the hashes and print the diff, but do not commit or push                                                              |
| `quiet`                | No       | `false`                                  | Silence the informational output                                                                                                |
| `install-dependencies` | No       | `true`                                   | Install missing system dependencies (`xmlstarlet`, `jq`, `curl`, `git`) with `apt-get`                                          |

\* One of `config` or `config-json` is required.

## Outputs

| Output            | Description                                                                                          |
|-------------------|------------------------------------------------------------------------------------------------------|
| `changed`         | `true` when at least one update server XML file received new hashes                                  |
| `dry-run`         | `true` when the action ran in dry-run mode                                                           |
| `updated`         | JSON array of `owner/repo@branch:path` targets that were pushed (or would be pushed in dry-run mode) |
| `updated-count`   | Number of updated targets                                                                            |
| `unchanged`       | JSON array of targets that already carried the correct hashes                                        |
| `unchanged-count` | Number of unchanged targets                                                                          |
| `failed`          | JSON array of `owner/repo@branch:path (reason)` entries                                              |
| `failed-count`    | Number of failed targets                                                                             |

The same numbers are written to the job summary of the workflow run.

---

# Install

```bash
sudo curl -L "https://raw.githubusercontent.com/octoleo/octoshoom/refs/heads/master/src/octoshoom" -o /usr/local/bin/octoshoom
sudo chmod +x /usr/local/bin/octoshoom
```

OctoShoom needs `git`, `curl`, `jq`, `xmlstarlet` and the GNU core utilities (`sha512sum`, `md5sum`, `unexpand`, `mktemp`) plus `awk`:

```bash
sudo apt-get install -y git curl jq xmlstarlet
```

---

# Usage

> To see the help menu:

```bash
octoshoom -h
```

---

## Help Menu (octoshoom)

```txt
Usage: octoshoom [OPTIONS]

Options:
======================================================
  -c | --config=<file>    Path to JSON configuration file
  -e | --env=<file>       Path to .env file with GIT variables
  -u | --git-url=<host>   SSH host of the Git server (e.g. github.com)
  -m | --message=<text>   Commit message (default: "chore: add sha512 hashes via OctoShoom")
  -o | --output=<file>    Append key=value results to this file (e.g. $GITHUB_OUTPUT)
  -d | --dry-run          Calculate hashes and show the diff, but do not commit or push
  -q | --quiet            Silence all output
  -V | --version          Display the version
  -h | --help             Display this help message

Environment Variables:
======================================================
  GIT_URL                   SSH domain (e.g. github.com, git.vdm.dev)
  GIT_AUTHOR_NAME           Git author name (optional, overrides the global git config)
  GIT_AUTHOR_EMAIL          Git author email (optional, overrides the global git config)
  GIT_GPG_SIGN              true|false (optional, overrides the global git config)
  GIT_SIGNING_KEY           GPG key ID (optional, overrides the global git config)
  OCTOSHOOM_CONF_FILE       Path to JSON configuration file
  OCTOSHOOM_ENV_FILE        Path to .env file (default: $HOME/.config/octoshoom/.env)
  OCTOSHOOM_COMMIT_MESSAGE  Commit message
  OCTOSHOOM_DRY_RUN         true|false
  OCTOSHOOM_OUTPUT_FILE     File that receives the key=value results
  OCTOSHOOM_SUMMARY_FILE    File that receives a Markdown summary (default: $GITHUB_STEP_SUMMARY)
  QUIET                     1|0

Precedence: command line options > env file > environment variables.

Results (written to the output file):
======================================================
  changed=true|false        At least one XML file received new hashes
  dry-run=true|false        Whether this was a dry run
  updated=[...]             JSON array of "owner/repo@branch:path" targets updated
  updated-count=<n>
  unchanged=[...]           JSON array of targets that were already up to date
  unchanged-count=<n>
  failed=[...]              JSON array of "target (reason)" entries
  failed-count=<n>

Exit code: 0 when every target succeeded, 1 otherwise.
======================================================
              OctoShoom v1.1.0
======================================================
```

---

### Local Environment Variables File

You can point OctoShoom to a custom `.env` file:

```bash
octoshoom --env="/home/username/.config/octoshoom/custom.env"
```

Or set the path via environment variable:

```bash
export OCTOSHOOM_ENV_FILE="/home/username/.config/octoshoom/custom.env"
```

> **Default path:** `$HOME/.config/octoshoom/.env` (loaded automatically when it exists)

Settings are resolved in this order: command line options win over the `.env` file, and the `.env` file wins over variables already exported in the environment.

---

### Git Identity and SSH Access

OctoShoom uses SSH for cloning, committing, and pushing repositories, so the SSH key of the Git user must be in place (the [octoleo/git-user](https://github.com/octoleo/git-user) action does this in a workflow). The SSH host is required; the Git identity and signing settings are optional and, when given, override the global Git configuration for the commits OctoShoom makes:

```bash
GIT_URL='git.vdm.dev'
GIT_AUTHOR_NAME='aB0t'
GIT_AUTHOR_EMAIL='robot@vdm.io'
GIT_GPG_SIGN=true
GIT_SIGNING_KEY='xxxxxxxxxxxxxxxxxxxxxxx'
```

These can also be exported before running the script:

```bash
export GIT_URL="git.vdm.dev"
export GIT_AUTHOR_NAME="aB0t"
export GIT_AUTHOR_EMAIL="robot@vdm.io"
```

Or passed on the command line:

```bash
octoshoom --git-url=git.vdm.dev --config="$HOME/.config/octoshoom/update_servers.json"
```

---

### JSON Configuration File

Your configuration file tells OctoShoom which repositories and XML files to process:

```jsonc
{
  "update_servers": [
    {
      "owner": "joomengine",
      "repo": "pkg-component-builder",
      "branch": "main",
      "path": "component_updates.xml"
    },
    {
      "owner": "joomengine",
      "repo": "another-repo",
      "branch": "master",
      "path": "admin/component_updates.xml"
    }
  ]
}
```

* **owner** – Git owner or namespace (e.g. `joomengine`)
* **repo** – Repository name (e.g. `pkg-component-builder`)
* **branch** – Branch to clone (defaults to `master`)
* **path** – Path to the XML file inside the repository root

Several entries may point to the same repository (different branches, or several XML files on one branch); the repository is cloned once.

OctoShoom will:

1. Shallow-clone each repo (`--depth=1`).
2. Parse the XML file.
3. Download each `<downloadurl>` ZIP file (each unique URL only once).
4. Generate a **SHA-512** hash for the file.
5. Insert (or replace) the `<sha512>` tag.
6. Commit and push changes back to the branch.
7. Delete the temporary clone to keep your system clean.

---

### Example Run

```bash
octoshoom --env="$HOME/.config/octoshoom/.env" --config="$HOME/.config/octoshoom/update_servers.json"
```

Preview the changes without pushing anything:

```bash
octoshoom --git-url=github.com --config="$HOME/.config/octoshoom/update_servers.json" --dry-run
```

Collect the results in a file (the format used by `$GITHUB_OUTPUT`):

```bash
octoshoom --git-url=github.com --config=update_servers.json --output=result.txt
cat result.txt
```

```txt
changed=true
dry-run=false
updated=["joomengine/pkg-component-builder@main:component_updates.xml"]
updated-count=1
unchanged=[]
unchanged-count=0
failed=[]
failed-count=0
```

---

## Testing

The test suite lives at `tests/test-octoshoom.sh`. It creates local bare Git repositories and package files in a sandbox, routes `git@localhost:` to those repositories, serves the packages through `file://` URLs and runs the script against them, so no network access or Git hosting account is needed. It also generates a GPG key to verify that signed commits work.

Tests run automatically on every push to master, on every pull request, and can be triggered manually from the Actions tab. The workflow also lints the scripts with ShellCheck and runs the action itself (`uses: ./`) end-to-end against a local repository.

#### Running Locally

```bash
bash tests/test-octoshoom.sh ./src/octoshoom
```

#### What The Tests Cover

- **Argument validation** — help, version, unknown options, missing values
- **Dependency check** — missing tools are named
- **Configuration validation** — missing file, invalid JSON, missing `update_servers`, entries without `owner`/`repo`/`path`, missing `GIT_URL`
- **Full run** — hashes injected, tab formatting, commit and push, results file
- **Idempotency** — a second run changes nothing
- **Dry run** — diff shown, nothing committed or pushed
- **Hash replacement** — stale `<sha512>` tags are replaced, duplicate URLs are downloaded once, URLs with XML entities are decoded
- **Several targets** — multiple branches and XML files per repository, default `master` branch
- **Failures** — missing branch, missing or malformed XML, failed download, missing repository; exit code `1` while the other targets are still processed
- **Commit message** — command line, environment, and precedence
- **Environment files** — `--env`, `OCTOSHOOM_ENV_FILE`, the default file, and precedence
- **Git identity** — exported variables and `.env` values, empty values ignored
- **GPG signing** — signed commits via variables and via the global git configuration
- **Quiet mode, option forms, summary and output files**

---

## Uninstall

```bash
sudo rm -f /usr/local/bin/octoshoom
```

---

# Free Software License

```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```
