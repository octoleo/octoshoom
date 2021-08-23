<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
OctoShoom - Automated Joomla Update Server Hash Injector
</h2>

Written by Llewellyn van der Merwe (@llewellynvdm)

With this script, we can automatically calculate **SHA-512 hashes** for every ZIP file listed in one or more Joomla update server XML files, inject those `<sha512>` tags into the XML, and push the changes back to their repositories — all from a single JSON configuration file, with environment variable support.

Linted by [#ShellCheck](https://github.com/koalaman/shellcheck)

> Program currently supports **Ubuntu/Debian** environments with **SSH-based Git access** (Gitea, GitHub, or GitLab).
> If you’d like to run this on other systems, please open an issue.

---

# Install

```bash
sudo curl -L "https://raw.githubusercontent.com/octoleo/octoshoom/refs/heads/master/src/octoshoom" -o /usr/local/bin/octoshoom
sudo chmod +x /usr/local/bin/octoshoom
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
  --config=<file>
    Path to JSON configuration file
    example: octoshoom --config=/src/update-servers.json
======================================================
  -e | --env=<file>
    Load environment variables file
    example: octoshoom --env=/home/username/.config/octoshoom/.env
======================================================
  -q | --quiet
    Mute all output messages
    example: octoshoom --quiet
======================================================
  -h | --help
    Display this help menu
    example: octoshoom --help
======================================================
            OctoShoom v1.0.0
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
export OCTOJSHA_ENV_FILE="/home/username/.config/octoshoom/custom.env"
```

> **Default path:** `/home/$USER/.config/octoshoom/.env`

---

### Git Identity and SSH Access

OctoShoom uses SSH for cloning, committing, and pushing repositories.
You must provide Git identity and host details either in `.env` or as environment variables:

```bash
GIT_AUTHOR_NAME='aB0t'
GIT_AUTHOR_EMAIL='robot@vdm.io'
GIT_GPG_SIGN=true
GIT_SIGNING_KEY='xxxxxxxxxxxxxxxxxxxxxxx'
GIT_URL='git.vdm.dev'
```

These can also be exported before running the script:

```bash
export GIT_AUTHOR_NAME="aB0t"
export GIT_AUTHOR_EMAIL="robot@vdm.io"
export GIT_URL="git.vdm.dev"
```

---

### JSON Configuration File

Your configuration file tells OctoShoom which repositories and XML files to process:

```jsonc
{
  "update_servers": [
    {
      "owner": "vdm-io",
      "repo": "pkg-component-builder",
      "branch": "main",
      "path": "component_updates.xml"
    },
    {
      "owner": "vdm-io",
      "repo": "another-repo",
      "branch": "master",
      "path": "admin/component_updates.xml"
    }
  ]
}
```

* **owner** – Git owner or namespace (e.g. `vdm-io`)
* **repo** – Repository name (e.g. `pkg-component-builder`)
* **branch** – Branch to clone (defaults to `master`)
* **path** – Path to the XML file inside the repository root

OctoShoom will:

1. Shallow-clone each repo (`--depth=1`).
2. Parse the XML file.
3. Download each `<downloadurl>` ZIP file.
4. Generate a **SHA-512** hash for the file.
5. Insert (or replace) the `<sha512>` tag.
6. Commit and push changes back to the branch.
7. Delete the temporary clone to keep your system clean.

---

### Example Run

```bash
octoshoom --env="$HOME/.config/octoshoom/.env" --config="$HOME/.config/octoshoom/update_servers.json"
```

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

