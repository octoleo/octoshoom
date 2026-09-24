#!/usr/bin/env bash
#
# tests/test-octoshoom.sh — Offline test suite for src/octoshoom
#
# Usage:
#   bash tests/test-octoshoom.sh [./src/octoshoom]
#
# The suite creates local bare Git repositories and package files inside a
# sandbox, rewrites "git@localhost:" to those repositories with git's
# url.<base>.insteadOf setting and serves the packages through file:// URLs,
# so no network access and no Git hosting account are needed.
#

set -uo pipefail

SCRIPT_ARG="${1:-$(dirname "$0")/../src/octoshoom}"
SCRIPT="$(cd "$(dirname "$SCRIPT_ARG")" && pwd)/$(basename "$SCRIPT_ARG")"

if [[ ! -f "$SCRIPT" ]]; then
	echo "Script not found: $SCRIPT" >&2
	exit 2
fi
chmod +x "$SCRIPT"

for cmd in git curl jq xmlstarlet sha512sum md5sum awk unexpand mktemp; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "Missing required command for the test suite: $cmd" >&2
		exit 2
	}
done

# ──────────────────────────────────────────────
# Test harness
# ──────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

if [[ -t 1 ]]; then
	C_GREEN=$'\e[32m' C_RED=$'\e[31m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
	C_GREEN="" C_RED="" C_BOLD="" C_RESET=""
fi

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
pass() {
	((TESTS_RUN++))
	((TESTS_PASSED++))
	printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}
fail() {
	((TESTS_RUN++))
	((TESTS_FAILED++))
	printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
}
assert_eq() {
	# name expected actual
	if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected: '$2' | got: '$3'"; fi
}
assert_contains() {
	# name haystack needle
	if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: '$3' | got: '${2:0:600}'"; fi
}
assert_not_contains() {
	# name haystack needle
	if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "expected NOT to contain: '$3'"; fi
}
assert_status() {
	# name expected actual
	if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected exit code $2 | got: $3"; fi
}

# ──────────────────────────────────────────────
# Sandbox
# ──────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export GNUPGHOME="$HOME/.gnupg"
export GIT_CONFIG_NOSYSTEM=1
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$HOME" "$GNUPGHOME" "$TMPDIR"
chmod 700 "$GNUPGHOME"

REMOTES="$SANDBOX/remotes"
PACKAGES="$SANDBOX/packages"
WORK="$SANDBOX/work"
mkdir -p "$REMOTES" "$PACKAGES" "$WORK"

unset GIT_URL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_GPG_SIGN GIT_SIGNING_KEY
unset OCTOSHOOM_CONF_FILE OCTOSHOOM_ENV_FILE OCTOSHOOM_DRY_RUN OCTOSHOOM_COMMIT_MESSAGE OCTOSHOOM_OUTPUT_FILE OCTOSHOOM_SUMMARY_FILE
unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT QUIET

git config --global user.name "Test Bot"
git config --global user.email "bot@example.com"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global uploadpack.allowFilter true
# Route git@localhost:owner/repo.git to the local bare repositories
git config --global url."file://${REMOTES}/".insteadOf "git@localhost:"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
make_package() {
	# @param $1 file name → prints the absolute path
	local file="$PACKAGES/$1"
	printf 'package:%s:%s\n' "$1" "$RANDOM$RANDOM" >"$file"
	echo "$file"
}

sha_of() { sha512sum "$1" | awk '{print $1}'; }

build_xml() {
	# @params "name|url[|sha]" ... → prints a Joomla update server XML (URL must be XML-escaped)
	local entry name url sha
	printf '<?xml version="1.0" encoding="utf-8"?>\n<updates>\n'
	for entry in "$@"; do
		IFS='|' read -r name url sha <<<"$entry"
		printf '\t<update>\n'
		printf '\t\t<name>%s</name>\n' "$name"
		printf '\t\t<element>com_demo</element>\n\t\t<type>component</type>\n\t\t<version>1.0.0</version>\n'
		printf '\t\t<downloads>\n\t\t\t<downloadurl type="full" format="zip">%s</downloadurl>\n\t\t</downloads>\n' "$url"
		[[ -n "${sha:-}" ]] && printf '\t\t<sha512>%s</sha512>\n' "$sha"
		printf '\t\t<targetplatform name="joomla" version="[45]\\.[0-9]"/>\n'
		printf '\t</update>\n'
	done
	printf '</updates>\n'
}

create_remote() {
	# @param $1 owner  $2 repo  $3 branch  $4 path  $5 file content
	local owner="$1" repo="$2" branch="$3" path="$4" content="$5"
	local bare="$REMOTES/$owner/$repo.git"
	local src
	src="$(mktemp -d -p "$WORK")"
	[[ -d "$bare" ]] || git init -q --bare "$bare"
	git -C "$src" init -q -b "$branch"
	mkdir -p "$src/$(dirname "$path")"
	printf '%s' "$content" >"$src/$path"
	git -C "$src" add -A
	git -C "$src" commit -q -m "init $branch"
	git -C "$src" push -q "file://$bare" "$branch"
	rm -rf "$src"
}

remote_file() { git --git-dir="$REMOTES/$1/$2.git" show "$3:$4"; }
remote_commits() { git --git-dir="$REMOTES/$1/$2.git" rev-list --count "$3"; }
remote_subject() { git --git-dir="$REMOTES/$1/$2.git" log -1 --format=%s "$3"; }
remote_author() { git --git-dir="$REMOTES/$1/$2.git" log -1 --format='%an <%ae>' "$3"; }
remote_signature() { git --git-dir="$REMOTES/$1/$2.git" log -1 --format=%G? "$3"; }

write_config() {
	# @param $1 file, then "owner|repo|branch|path" entries (empty branch = omitted)
	local file="$1"
	shift
	local entries=() e owner repo branch path
	for e in "$@"; do
		IFS='|' read -r owner repo branch path <<<"$e"
		if [[ -n "$branch" ]]; then
			entries+=("$(jq -nc --arg o "$owner" --arg r "$repo" --arg b "$branch" --arg p "$path" '{owner:$o,repo:$r,branch:$b,path:$p}')")
		else
			entries+=("$(jq -nc --arg o "$owner" --arg r "$repo" --arg p "$path" '{owner:$o,repo:$r,path:$p}')")
		fi
	done
	printf '%s\n' "${entries[@]}" | jq -s '{update_servers: .}' >"$file"
}

OUTPUT=""
STATUS=0
run_octoshoom() {
	OUTPUT="$("$SCRIPT" "$@" 2>&1)"
	STATUS=$?
}
run_octoshoom_stdout() {
	OUTPUT="$("$SCRIPT" "$@" 2>/dev/null)"
	STATUS=$?
}
output_value() {
	# @param $1 output file  $2 key
	grep "^$2=" "$1" | tail -1 | cut -d= -f2-
}
count_lines() { grep -c "$2" <<<"$1" || true; }

printf '%s\n' "octoshoom — Test Suite"
printf 'Script:  %s\n' "$SCRIPT"
printf 'Sandbox: %s\n' "$SANDBOX"

# ──────────────────────────────────────────────
section "Help, version and option parsing"
# ──────────────────────────────────────────────
run_octoshoom --help
assert_status "--help exits 0" 0 "$STATUS"
assert_contains "--help shows usage" "$OUTPUT" "Usage: octoshoom [OPTIONS]"
assert_contains "--help documents --dry-run" "$OUTPUT" "--dry-run"
assert_contains "--help documents --output" "$OUTPUT" "--output"

run_octoshoom -h
assert_status "-h exits 0" 0 "$STATUS"

run_octoshoom --version
assert_status "--version exits 0" 0 "$STATUS"
assert_contains "--version prints the version" "$OUTPUT" "OctoShoom v"

run_octoshoom --bogus
assert_status "unknown option exits 1" 1 "$STATUS"
assert_contains "unknown option is reported" "$OUTPUT" "Unknown option: --bogus"

run_octoshoom --config
assert_status "--config without value exits 1" 1 "$STATUS"
assert_contains "--config without value is reported" "$OUTPUT" "requires a value"

run_octoshoom stray-argument
assert_status "stray argument exits 1" 1 "$STATUS"
assert_contains "stray argument is reported" "$OUTPUT" "Unexpected argument: stray-argument"

# ──────────────────────────────────────────────
section "Dependency check"
# ──────────────────────────────────────────────
mkdir -p "$SANDBOX/nobin"
OUTPUT="$(PATH="$SANDBOX/nobin" "$SCRIPT" --config=/dev/null 2>&1)"
STATUS=$?
assert_status "missing dependencies exit 1" 1 "$STATUS"
assert_contains "missing dependencies are listed" "$OUTPUT" "We require"
assert_contains "missing xmlstarlet is listed" "$OUTPUT" "xmlstarlet"
assert_contains "missing jq is listed" "$OUTPUT" "jq"

# ──────────────────────────────────────────────
section "Configuration validation"
# ──────────────────────────────────────────────
run_octoshoom --git-url=localhost
assert_status "no config exits 1" 1 "$STATUS"
assert_contains "no config is reported" "$OUTPUT" "No config file given"

run_octoshoom --git-url=localhost --config="$SANDBOX/does-not-exist.json"
assert_status "missing config file exits 1" 1 "$STATUS"
assert_contains "missing config file is reported" "$OUTPUT" "Config file not found"

echo '{}' >"$SANDBOX/empty.json"
run_octoshoom --git-url=localhost --config="$SANDBOX/empty.json"
assert_status "config without update_servers exits 1" 1 "$STATUS"
assert_contains "config without update_servers is reported" "$OUTPUT" 'non-empty "update_servers" array'

echo '{"update_servers": []}' >"$SANDBOX/emptylist.json"
run_octoshoom --git-url=localhost --config="$SANDBOX/emptylist.json"
assert_status "config with empty update_servers exits 1" 1 "$STATUS"

echo '{"update_servers": [{"owner": "joomengine", "path": "x.xml"}]}' >"$SANDBOX/norepo.json"
run_octoshoom --git-url=localhost --config="$SANDBOX/norepo.json"
assert_status "config entry without repo exits 1" 1 "$STATUS"
assert_contains "config entry without repo is reported" "$OUTPUT" 'needs "owner", "repo" and "path"'

echo 'not json' >"$SANDBOX/broken.json"
run_octoshoom --git-url=localhost --config="$SANDBOX/broken.json"
assert_status "invalid JSON exits 1" 1 "$STATUS"

write_config "$SANDBOX/valid.json" "joomengine|alpha|main|component_updates.xml"
run_octoshoom --config="$SANDBOX/valid.json"
assert_status "missing GIT_URL exits 1" 1 "$STATUS"
assert_contains "missing GIT_URL is reported" "$OUTPUT" "GIT_URL is not set"

# ──────────────────────────────────────────────
section "Full run: hashes injected, committed and pushed"
# ──────────────────────────────────────────────
ALPHA_PKG="$(make_package alpha-1.0.0.zip)"
ALPHA_SHA="$(sha_of "$ALPHA_PKG")"
create_remote joomengine alpha main component_updates.xml "$(build_xml "Alpha|file://$ALPHA_PKG")"
write_config "$SANDBOX/alpha.json" "joomengine|alpha|main|component_updates.xml"
ALPHA_OUT="$SANDBOX/alpha.out"

run_octoshoom --git-url=localhost --config="$SANDBOX/alpha.json" --output="$ALPHA_OUT"
assert_status "full run exits 0" 0 "$STATUS"
assert_contains "full run reports the push" "$OUTPUT" "[success] Pushed updates for joomengine/alpha@main:component_updates.xml"
assert_contains "full run reports success" "$OUTPUT" "[Success] All update servers processed"
ALPHA_XML="$(remote_file joomengine alpha main component_updates.xml)"
assert_contains "sha512 is injected into the remote XML" "$ALPHA_XML" "<sha512>${ALPHA_SHA}</sha512>"
assert_eq "exactly one sha512 tag" "1" "$(count_lines "$ALPHA_XML" "<sha512>")"
assert_contains "XML is tab indented" "$ALPHA_XML" $'\n\t\t<sha512>'
assert_eq "one new commit on the remote" "2" "$(remote_commits joomengine alpha main)"
assert_eq "default commit message" "chore: add sha512 hashes via OctoShoom" "$(remote_subject joomengine alpha main)"
assert_eq "output: changed" "true" "$(output_value "$ALPHA_OUT" changed)"
assert_eq "output: dry-run" "false" "$(output_value "$ALPHA_OUT" dry-run)"
assert_eq "output: updated" '["joomengine/alpha@main:component_updates.xml"]' "$(output_value "$ALPHA_OUT" updated)"
assert_eq "output: updated-count" "1" "$(output_value "$ALPHA_OUT" updated-count)"
assert_eq "output: unchanged" '[]' "$(output_value "$ALPHA_OUT" unchanged)"
assert_eq "output: failed" '[]' "$(output_value "$ALPHA_OUT" failed)"
assert_eq "output: failed-count" "0" "$(output_value "$ALPHA_OUT" failed-count)"
assert_eq "temporary clone directories are removed" "" "$(ls -A "$TMPDIR")"

# ──────────────────────────────────────────────
section "Second run: nothing changes"
# ──────────────────────────────────────────────
ALPHA_OUT2="$SANDBOX/alpha2.out"
run_octoshoom --git-url=localhost --config="$SANDBOX/alpha.json" --output="$ALPHA_OUT2"
assert_status "second run exits 0" 0 "$STATUS"
assert_contains "second run detects no changes" "$OUTPUT" "No changes detected in component_updates.xml"
assert_eq "no new commit on the remote" "2" "$(remote_commits joomengine alpha main)"
assert_eq "output: changed is false" "false" "$(output_value "$ALPHA_OUT2" changed)"
assert_eq "output: unchanged" '["joomengine/alpha@main:component_updates.xml"]' "$(output_value "$ALPHA_OUT2" unchanged)"
assert_eq "output: unchanged-count" "1" "$(output_value "$ALPHA_OUT2" unchanged-count)"
assert_eq "output: updated-count is 0" "0" "$(output_value "$ALPHA_OUT2" updated-count)"

# ──────────────────────────────────────────────
section "Dry run: nothing is committed or pushed"
# ──────────────────────────────────────────────
BETA_PKG="$(make_package beta-1.0.0.zip)"
BETA_SHA="$(sha_of "$BETA_PKG")"
create_remote joomengine beta main component_updates.xml "$(build_xml "Beta|file://$BETA_PKG")"
write_config "$SANDBOX/beta.json" "joomengine|beta|main|component_updates.xml"
BETA_OUT="$SANDBOX/beta.out"

run_octoshoom --git-url=localhost --config="$SANDBOX/beta.json" --dry-run --output="$BETA_OUT"
assert_status "dry run exits 0" 0 "$STATUS"
assert_contains "dry run announces itself" "$OUTPUT" "Dry-run mode"
assert_contains "dry run reports the pending change" "$OUTPUT" "[dry-run] Changes detected in component_updates.xml"
assert_contains "dry run prints the diff" "$OUTPUT" "+		<sha512>${BETA_SHA}</sha512>"
assert_eq "dry run pushes nothing" "1" "$(remote_commits joomengine beta main)"
assert_not_contains "dry run leaves the remote XML untouched" "$(remote_file joomengine beta main component_updates.xml)" "<sha512>"
assert_eq "output: dry-run is true" "true" "$(output_value "$BETA_OUT" dry-run)"
assert_eq "output: changed is true" "true" "$(output_value "$BETA_OUT" changed)"
assert_eq "output: updated lists the target" '["joomengine/beta@main:component_updates.xml"]' "$(output_value "$BETA_OUT" updated)"

OUTPUT="$(OCTOSHOOM_DRY_RUN=true "$SCRIPT" --git-url=localhost --config="$SANDBOX/beta.json" 2>&1)"
STATUS=$?
assert_status "OCTOSHOOM_DRY_RUN=true exits 0" 0 "$STATUS"
assert_eq "OCTOSHOOM_DRY_RUN=true pushes nothing" "1" "$(remote_commits joomengine beta main)"

run_octoshoom --git-url=localhost --config="$SANDBOX/beta.json"
assert_status "real run after dry run exits 0" 0 "$STATUS"
assert_eq "real run after dry run pushes" "2" "$(remote_commits joomengine beta main)"
assert_contains "real run injects the hash" "$(remote_file joomengine beta main component_updates.xml)" "<sha512>${BETA_SHA}</sha512>"

# ──────────────────────────────────────────────
section "Existing sha512 tags are replaced"
# ──────────────────────────────────────────────
GAMMA_PKG="$(make_package gamma-1.0.0.zip)"
GAMMA_SHA="$(sha_of "$GAMMA_PKG")"
create_remote joomengine gamma main component_updates.xml "$(build_xml "Gamma|file://$GAMMA_PKG|deadbeef")"
write_config "$SANDBOX/gamma.json" "joomengine|gamma|main|component_updates.xml"

run_octoshoom --git-url=localhost --config="$SANDBOX/gamma.json"
assert_status "run with stale sha512 exits 0" 0 "$STATUS"
GAMMA_XML="$(remote_file joomengine gamma main component_updates.xml)"
assert_contains "new sha512 is present" "$GAMMA_XML" "<sha512>${GAMMA_SHA}</sha512>"
assert_not_contains "stale sha512 is gone" "$GAMMA_XML" "deadbeef"
assert_eq "only one sha512 tag remains" "1" "$(count_lines "$GAMMA_XML" "<sha512>")"

# ──────────────────────────────────────────────
section "Duplicate download URLs are downloaded once"
# ──────────────────────────────────────────────
DELTA_PKG="$(make_package delta-1.0.0.zip)"
DELTA_SHA="$(sha_of "$DELTA_PKG")"
create_remote joomengine delta main component_updates.xml "$(build_xml "Delta J4|file://$DELTA_PKG" "Delta J5|file://$DELTA_PKG")"
write_config "$SANDBOX/delta.json" "joomengine|delta|main|component_updates.xml"

run_octoshoom --git-url=localhost --config="$SANDBOX/delta.json"
assert_status "duplicate URL run exits 0" 0 "$STATUS"
DELTA_XML="$(remote_file joomengine delta main component_updates.xml)"
assert_eq "both update nodes receive the sha512" "2" "$(count_lines "$DELTA_XML" "<sha512>${DELTA_SHA}</sha512>")"
assert_eq "package downloaded only once" "1" "$(count_lines "$OUTPUT" "Downloading package: delta-1.0.0.zip")"

# ──────────────────────────────────────────────
section "Download URLs with XML entities are decoded"
# ──────────────────────────────────────────────
EPSILON_PKG="$(make_package 'epsilon&1.0.0.zip')"
EPSILON_SHA="$(sha_of "$EPSILON_PKG")"
create_remote joomengine epsilon main component_updates.xml "$(build_xml "Epsilon|file://${EPSILON_PKG//&/&amp;}")"
write_config "$SANDBOX/epsilon.json" "joomengine|epsilon|main|component_updates.xml"

run_octoshoom --git-url=localhost --config="$SANDBOX/epsilon.json"
assert_status "entity URL run exits 0" 0 "$STATUS"
EPSILON_XML="$(remote_file joomengine epsilon main component_updates.xml)"
assert_contains "entity URL hash is correct" "$EPSILON_XML" "<sha512>${EPSILON_SHA}</sha512>"
assert_contains "entity URL stays escaped in the XML" "$EPSILON_XML" "epsilon&amp;1.0.0.zip"

# ──────────────────────────────────────────────
section "Several branches and XML files in one repository"
# ──────────────────────────────────────────────
ZETA_A="$(make_package zeta-a.zip)"
ZETA_B="$(make_package zeta-b.zip)"
ZETA_C="$(make_package zeta-c.zip)"
create_remote joomengine zeta main a/updates.xml "$(build_xml "Zeta A|file://$ZETA_A")"
# second file on the same branch
ZETA_SRC="$(mktemp -d -p "$WORK")"
git clone -q "file://$REMOTES/joomengine/zeta.git" "$ZETA_SRC"
mkdir -p "$ZETA_SRC/b"
build_xml "Zeta B|file://$ZETA_B" >"$ZETA_SRC/b/updates.xml"
git -C "$ZETA_SRC" add -A && git -C "$ZETA_SRC" commit -q -m "add b" && git -C "$ZETA_SRC" push -q origin main
rm -rf "$ZETA_SRC"
create_remote joomengine zeta dev updates.xml "$(build_xml "Zeta C|file://$ZETA_C")"
write_config "$SANDBOX/zeta.json" "joomengine|zeta|main|a/updates.xml" "joomengine|zeta|main|b/updates.xml" "joomengine|zeta|dev|updates.xml"
ZETA_OUT="$SANDBOX/zeta.out"

run_octoshoom --git-url=localhost --config="$SANDBOX/zeta.json" --output="$ZETA_OUT"
assert_status "multi target run exits 0" 0 "$STATUS"
assert_eq "repository cloned once" "1" "$(count_lines "$OUTPUT" "Cloning joomengine/zeta")"
assert_contains "main a/updates.xml hashed" "$(remote_file joomengine zeta main a/updates.xml)" "<sha512>$(sha_of "$ZETA_A")</sha512>"
assert_contains "main b/updates.xml hashed" "$(remote_file joomengine zeta main b/updates.xml)" "<sha512>$(sha_of "$ZETA_B")</sha512>"
assert_contains "dev updates.xml hashed" "$(remote_file joomengine zeta dev updates.xml)" "<sha512>$(sha_of "$ZETA_C")</sha512>"
assert_eq "two new commits on main" "4" "$(remote_commits joomengine zeta main)"
assert_eq "one new commit on dev" "2" "$(remote_commits joomengine zeta dev)"
assert_eq "output: updated-count" "3" "$(output_value "$ZETA_OUT" updated-count)"

# ──────────────────────────────────────────────
section "Default branch is master when omitted"
# ──────────────────────────────────────────────
ETA_PKG="$(make_package eta.zip)"
create_remote joomengine eta master component_updates.xml "$(build_xml "Eta|file://$ETA_PKG")"
write_config "$SANDBOX/eta.json" "joomengine|eta||component_updates.xml"

run_octoshoom --git-url=localhost --config="$SANDBOX/eta.json"
assert_status "run without branch exits 0" 0 "$STATUS"
assert_contains "master branch is used" "$OUTPUT" "Pushed updates for joomengine/eta@master:component_updates.xml"
assert_contains "master branch hashed" "$(remote_file joomengine eta master component_updates.xml)" "<sha512>$(sha_of "$ETA_PKG")</sha512>"

# ──────────────────────────────────────────────
section "Failures are reported and the exit code is 1"
# ──────────────────────────────────────────────
FAIL_OUT="$SANDBOX/fail.out"
write_config "$SANDBOX/missing-branch.json" "joomengine|alpha|nope|component_updates.xml" "joomengine|alpha|main|component_updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/missing-branch.json" --output="$FAIL_OUT"
assert_status "missing branch exits 1" 1 "$STATUS"
assert_contains "missing branch is reported" "$OUTPUT" "branch 'nope' not found on remote joomengine/alpha"
assert_contains "other target is still processed" "$OUTPUT" "No changes detected in component_updates.xml"
assert_eq "output: failed-count" "1" "$(output_value "$FAIL_OUT" failed-count)"
assert_eq "output: unchanged-count" "1" "$(output_value "$FAIL_OUT" unchanged-count)"
assert_contains "output: failed lists the reason" "$(output_value "$FAIL_OUT" failed)" "joomengine/alpha@nope:component_updates.xml (branch 'nope' not found"
assert_eq "temporary clone directories are removed after failures" "" "$(ls -A "$TMPDIR")"

write_config "$SANDBOX/missing-xml.json" "joomengine|alpha|main|nope/updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/missing-xml.json"
assert_status "missing XML exits 1" 1 "$STATUS"
assert_contains "missing XML is reported" "$OUTPUT" "XML file 'nope/updates.xml' not found in branch 'main'"

create_remote joomengine theta main component_updates.xml "<updates><update><name>broken</update></updates>"
write_config "$SANDBOX/theta.json" "joomengine|theta|main|component_updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/theta.json"
assert_status "malformed XML exits 1" 1 "$STATUS"
assert_contains "malformed XML is reported" "$OUTPUT" "is not well-formed"
assert_eq "malformed XML is not pushed" "1" "$(remote_commits joomengine theta main)"

IOTA_PKG="$(make_package iota.zip)"
create_remote joomengine iota main component_updates.xml "$(build_xml "Iota good|file://$IOTA_PKG" "Iota bad|file://$PACKAGES/does-not-exist.zip")"
write_config "$SANDBOX/iota.json" "joomengine|iota|main|component_updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/iota.json" --output="$FAIL_OUT"
assert_status "failed download exits 1" 1 "$STATUS"
assert_contains "failed download is reported" "$OUTPUT" "download failed: file://$PACKAGES/does-not-exist.zip"
IOTA_XML="$(remote_file joomengine iota main component_updates.xml)"
assert_contains "successful hash is still pushed" "$IOTA_XML" "<sha512>$(sha_of "$IOTA_PKG")</sha512>"
assert_eq "only the successful hash is present" "1" "$(count_lines "$IOTA_XML" "<sha512>")"
assert_eq "output: changed is true despite a failure" "true" "$(output_value "$FAIL_OUT" changed)"
assert_eq "output: failed-count after download failure" "1" "$(output_value "$FAIL_OUT" failed-count)"

write_config "$SANDBOX/missing-repo.json" "joomengine|does-not-exist|main|component_updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/missing-repo.json"
assert_status "missing repository exits 1" 1 "$STATUS"
assert_contains "missing repository is reported" "$OUTPUT" "clone failed for git@localhost:joomengine/does-not-exist.git"

create_remote joomengine lambda main component_updates.xml "$(printf '<?xml version="1.0" encoding="utf-8"?>\n<updates>\n\t<update>\n\t\t<name>No URL</name>\n\t</update>\n</updates>\n')"
write_config "$SANDBOX/lambda.json" "joomengine|lambda|main|component_updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/lambda.json"
assert_status "XML without downloadurl exits 0" 0 "$STATUS"
assert_contains "XML without downloadurl is reported" "$OUTPUT" "No <downloadurl> found in joomengine/lambda@main:component_updates.xml"

# ──────────────────────────────────────────────
section "Commit message"
# ──────────────────────────────────────────────
MU_PKG="$(make_package mu.zip)"
create_remote joomengine mu main component_updates.xml "$(build_xml "Mu|file://$MU_PKG")"
write_config "$SANDBOX/mu.json" "joomengine|mu|main|component_updates.xml"
run_octoshoom --git-url=localhost --config="$SANDBOX/mu.json" --message="chore: custom message"
assert_status "custom commit message exits 0" 0 "$STATUS"
assert_eq "custom commit message is used" "chore: custom message" "$(remote_subject joomengine mu main)"

create_remote joomengine nu main component_updates.xml "$(build_xml "Nu|file://$MU_PKG")"
write_config "$SANDBOX/nu.json" "joomengine|nu|main|component_updates.xml"
OUTPUT="$(OCTOSHOOM_COMMIT_MESSAGE="chore: from environment" "$SCRIPT" --git-url=localhost --config="$SANDBOX/nu.json" 2>&1)"
STATUS=$?
assert_status "OCTOSHOOM_COMMIT_MESSAGE exits 0" 0 "$STATUS"
assert_eq "OCTOSHOOM_COMMIT_MESSAGE is used" "chore: from environment" "$(remote_subject joomengine nu main)"

create_remote joomengine xi main component_updates.xml "$(build_xml "Xi|file://$MU_PKG")"
write_config "$SANDBOX/xi.json" "joomengine|xi|main|component_updates.xml"
OUTPUT="$(OCTOSHOOM_COMMIT_MESSAGE="chore: from environment" "$SCRIPT" --git-url=localhost --config="$SANDBOX/xi.json" -m "chore: from cli" 2>&1)"
STATUS=$?
assert_status "command line message over environment exits 0" 0 "$STATUS"
assert_eq "command line message wins over environment" "chore: from cli" "$(remote_subject joomengine xi main)"

# ──────────────────────────────────────────────
section "Environment files and precedence"
# ──────────────────────────────────────────────
OMICRON_PKG="$(make_package omicron.zip)"
create_remote joomengine omicron main component_updates.xml "$(build_xml "Omicron|file://$OMICRON_PKG")"
write_config "$SANDBOX/omicron.json" "joomengine|omicron|main|component_updates.xml"
cat >"$SANDBOX/good.env" <<EOF
GIT_URL=localhost
GIT_AUTHOR_NAME='Env Bot'
GIT_AUTHOR_EMAIL='env@example.com'
EOF
run_octoshoom --env="$SANDBOX/good.env" --config="$SANDBOX/omicron.json"
assert_status "env file run exits 0" 0 "$STATUS"
assert_contains "env file is announced" "$OUTPUT" "Loaded environment file: $SANDBOX/good.env"
assert_eq "env file git identity is used" "Env Bot <env@example.com>" "$(remote_author joomengine omicron main)"

run_octoshoom --env="$SANDBOX/missing.env" --config="$SANDBOX/omicron.json"
assert_status "missing env file exits 1" 1 "$STATUS"
assert_contains "missing env file is reported" "$OUTPUT" "Environment file not found: $SANDBOX/missing.env"

cat >"$SANDBOX/bad-host.env" <<EOF
GIT_URL=bogus.invalid
EOF
run_octoshoom --env="$SANDBOX/bad-host.env" --git-url=localhost --config="$SANDBOX/omicron.json"
assert_status "command line git-url wins over env file" 0 "$STATUS"

OUTPUT="$(GIT_URL=bogus.invalid "$SCRIPT" --env="$SANDBOX/good.env" --config="$SANDBOX/omicron.json" 2>&1)"
STATUS=$?
assert_status "env file wins over process environment" 0 "$STATUS"

OUTPUT="$(GIT_URL=localhost OCTOSHOOM_CONF_FILE="$SANDBOX/omicron.json" "$SCRIPT" 2>&1)"
STATUS=$?
assert_status "GIT_URL and OCTOSHOOM_CONF_FILE from the environment" 0 "$STATUS"

OUTPUT="$(OCTOSHOOM_ENV_FILE="$SANDBOX/good.env" "$SCRIPT" --config="$SANDBOX/omicron.json" 2>&1)"
STATUS=$?
assert_status "OCTOSHOOM_ENV_FILE exits 0" 0 "$STATUS"
assert_contains "OCTOSHOOM_ENV_FILE is loaded" "$OUTPUT" "Loaded environment file: $SANDBOX/good.env"

mkdir -p "$HOME/.config/octoshoom"
cp "$SANDBOX/good.env" "$HOME/.config/octoshoom/.env"
run_octoshoom --config="$SANDBOX/omicron.json"
assert_status "default env file exits 0" 0 "$STATUS"
assert_contains "default env file is loaded" "$OUTPUT" "Loaded environment file: $HOME/.config/octoshoom/.env"
rm -f "$HOME/.config/octoshoom/.env"

# ──────────────────────────────────────────────
section "Git identity from exported variables"
# ──────────────────────────────────────────────
PI_PKG="$(make_package pi.zip)"
create_remote joomengine pi main component_updates.xml "$(build_xml "Pi|file://$PI_PKG")"
write_config "$SANDBOX/pi.json" "joomengine|pi|main|component_updates.xml"
OUTPUT="$(GIT_AUTHOR_NAME="Exported Bot" GIT_AUTHOR_EMAIL="exported@example.com" "$SCRIPT" --git-url=localhost --config="$SANDBOX/pi.json" 2>&1)"
STATUS=$?
assert_status "exported identity run exits 0" 0 "$STATUS"
assert_contains "exported identity is announced" "$OUTPUT" "Git author name set: Exported Bot"
assert_eq "exported identity is used" "Exported Bot <exported@example.com>" "$(remote_author joomengine pi main)"

OUTPUT="$(GIT_AUTHOR_NAME="" GIT_AUTHOR_EMAIL="" "$SCRIPT" --git-url=localhost --config="$SANDBOX/pi.json" 2>&1)"
STATUS=$?
assert_status "empty identity variables are ignored" 0 "$STATUS"
assert_not_contains "empty identity variables are not applied" "$OUTPUT" "Git author name set"

# ──────────────────────────────────────────────
section "GPG signed commits"
# ──────────────────────────────────────────────
GPG_KEY_ID=""
if command -v gpg >/dev/null 2>&1; then
	gpg --batch --quiet --gen-key 2>/dev/null <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Test Bot
Name-Email: bot@example.com
Expire-Date: 0
%commit
EOF
	GPG_KEY_ID="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "sec" { print $5; exit }')"
fi
if [[ -n "$GPG_KEY_ID" ]]; then
	RHO_PKG="$(make_package rho.zip)"
	create_remote joomengine rho main component_updates.xml "$(build_xml "Rho|file://$RHO_PKG")"
	write_config "$SANDBOX/rho.json" "joomengine|rho|main|component_updates.xml"
	OUTPUT="$(GIT_GPG_SIGN=true GIT_SIGNING_KEY="$GPG_KEY_ID" "$SCRIPT" --git-url=localhost --config="$SANDBOX/rho.json" 2>&1)"
	STATUS=$?
	assert_status "signed run exits 0" 0 "$STATUS"
	assert_contains "signing is announced" "$OUTPUT" "Git commit signing: true"
	assert_eq "commit carries a good signature" "G" "$(remote_signature joomengine rho main)"

	# a global signing setup (as configured by octoleo/git-user) is honoured without any variables
	git config --global user.signingkey "$GPG_KEY_ID"
	git config --global commit.gpgsign true
	SIGMA_PKG="$(make_package sigma.zip)"
	create_remote joomengine sigma main component_updates.xml "$(build_xml "Sigma|file://$SIGMA_PKG")"
	write_config "$SANDBOX/sigma.json" "joomengine|sigma|main|component_updates.xml"
	run_octoshoom --git-url=localhost --config="$SANDBOX/sigma.json"
	assert_status "global signing run exits 0" 0 "$STATUS"
	assert_eq "global signing configuration is honoured" "G" "$(remote_signature joomengine sigma main)"
	git config --global commit.gpgsign false
	gpgconf --kill gpg-agent >/dev/null 2>&1 || true
else
	echo "  SKIP GPG tests (gpg not available or key generation failed)"
fi

# ──────────────────────────────────────────────
section "Quiet mode, option forms, summary file"
# ──────────────────────────────────────────────
run_octoshoom_stdout -q --git-url=localhost --config="$SANDBOX/alpha.json"
assert_status "quiet run exits 0" 0 "$STATUS"
assert_eq "quiet run prints nothing on stdout" "" "$OUTPUT"

OUTPUT="$(QUIET=1 "$SCRIPT" --git-url=localhost --config="$SANDBOX/alpha.json" 2>/dev/null)"
STATUS=$?
assert_status "QUIET=1 run exits 0" 0 "$STATUS"
assert_eq "QUIET=1 prints nothing on stdout" "" "$OUTPUT"

run_octoshoom_stdout -q --git-url=localhost --config="$SANDBOX/missing-branch.json"
assert_status "quiet failure still exits 1" 1 "$STATUS"

TAU_PKG="$(make_package tau.zip)"
create_remote joomengine tau main component_updates.xml "$(build_xml "Tau|file://$TAU_PKG")"
write_config "$SANDBOX/tau.json" "joomengine|tau|main|component_updates.xml"
run_octoshoom --config "$SANDBOX/tau.json" --git-url localhost -m "chore: spaced options"
assert_status "space separated options exit 0" 0 "$STATUS"
assert_eq "space separated options are applied" "chore: spaced options" "$(remote_subject joomengine tau main)"

SUMMARY="$SANDBOX/summary.md"
OUTPUT="$(OCTOSHOOM_SUMMARY_FILE="$SUMMARY" "$SCRIPT" --git-url=localhost --config="$SANDBOX/alpha.json" 2>&1)"
STATUS=$?
assert_status "summary file run exits 0" 0 "$STATUS"
assert_contains "summary has a title" "$(cat "$SUMMARY")" "## OctoShoom v"
assert_contains "summary has the counts table" "$(cat "$SUMMARY")" "| Unchanged | 1 |"
assert_contains "summary lists the target" "$(cat "$SUMMARY")" "- \`joomengine/alpha@main:component_updates.xml\`"

SUMMARY2="$SANDBOX/summary2.md"
OUTPUT="$(GITHUB_STEP_SUMMARY="$SUMMARY2" "$SCRIPT" --git-url=localhost --config="$SANDBOX/alpha.json" 2>&1)"
STATUS=$?
assert_status "GITHUB_STEP_SUMMARY run exits 0" 0 "$STATUS"
assert_contains "GITHUB_STEP_SUMMARY is used by default" "$(cat "$SUMMARY2")" "## OctoShoom v"

ENV_OUT="$SANDBOX/env.out"
OUTPUT="$(OCTOSHOOM_OUTPUT_FILE="$ENV_OUT" "$SCRIPT" --git-url=localhost --config="$SANDBOX/alpha.json" 2>&1)"
STATUS=$?
assert_status "OCTOSHOOM_OUTPUT_FILE run exits 0" 0 "$STATUS"
assert_eq "OCTOSHOOM_OUTPUT_FILE receives the results" "false" "$(output_value "$ENV_OUT" changed)"

REL_DIR="$SANDBOX/relative"
mkdir -p "$REL_DIR"
cp "$SANDBOX/alpha.json" "$REL_DIR/conf.json"
OUTPUT="$(cd "$REL_DIR" && "$SCRIPT" --git-url=localhost --config=conf.json --output=result.out 2>&1)"
STATUS=$?
assert_status "relative paths exit 0" 0 "$STATUS"
assert_eq "relative output file is written next to the config" "false" "$(output_value "$REL_DIR/result.out" changed)"

# ──────────────────────────────────────────────
# Results
# ──────────────────────────────────────────────
printf '\n════════════════════════════════════════\n'
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Passed:       %d\n' "$TESTS_PASSED"
printf 'Failed:       %d\n' "$TESTS_FAILED"
printf '\n'
if ((TESTS_FAILED == 0)); then
	printf '%sALL TESTS PASSED%s\n' "$C_GREEN" "$C_RESET"
	exit 0
fi
printf '%sSOME TESTS FAILED%s\n' "$C_RED" "$C_RESET"
exit 1
