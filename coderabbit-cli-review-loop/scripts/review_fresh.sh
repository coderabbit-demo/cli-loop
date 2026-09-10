#!/usr/bin/env bash

set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage: review_fresh.sh [--repo PATH] [--base REF | --base-commit SHA]
                       [--dry-run]

Reconstructs the full feature state from its base in a temporary clone and runs one
independent normal CodeRabbit --agent review. This includes committed, staged,
unstaged, and untracked feature changes. The clone is removed after the command.
EOF
}

repo="."
base="main"
base_commit=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo requires a value"; repo="$2"; shift 2 ;;
    --base) [[ $# -ge 2 ]] || die "--base requires a value"; base="$2"; shift 2 ;;
    --base-commit) [[ $# -ge 2 ]] || die "--base-commit requires a value"; base_commit="$2"; base=""; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --light|--use-credits|--api-key) die "$1 is intentionally forbidden" ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v coderabbit >/dev/null 2>&1 || die "coderabbit is not installed"
command -v shasum >/dev/null 2>&1 || die "shasum is not installed"

cli_version="$(coderabbit --version 2>/dev/null | head -n 1)"
normalized_version="${cli_version#v}"
[[ "$normalized_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+][0-9A-Za-z.-]+)?$ ]] || die "cannot parse CodeRabbit CLI version: $cli_version"
if (( BASH_REMATCH[1] == 0 && BASH_REMATCH[2] < 4 )); then
  die "CodeRabbit CLI 0.4.0 or newer is required; found $cli_version"
fi

repo="$(cd "$repo" 2>/dev/null && pwd)" || die "cannot access repository"
repo_root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "not a Git repository"
branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD)" || die "detached HEAD is not supported"

if [[ -n "$base_commit" ]]; then
  comparison="$(git -C "$repo_root" rev-parse --verify "${base_commit}^{commit}")" || die "invalid base commit"
else
  base_ref="$(git -C "$repo_root" rev-parse --verify "origin/${base}^{commit}" 2>/dev/null || git -C "$repo_root" rev-parse --verify "${base}^{commit}" 2>/dev/null)" || die "cannot resolve base: $base"
  comparison="$(git -C "$repo_root" merge-base HEAD "$base_ref")" || die "cannot determine merge base for: $base"
fi

untracked_paths="$(git -C "$repo_root" ls-files --others --exclude-standard)"
if git -C "$repo_root" diff --quiet "$comparison" -- && [[ -z "$untracked_paths" ]]; then
  die "no feature changes to review against base commit $comparison"
fi

scope="full-state-uncommitted"
fingerprint="$({
  printf 'base=%s\n' "$comparison"
  git -C "$repo_root" diff --binary "$comparison" --
  while IFS= read -r -d '' path; do
    file_hash="$(shasum -a 256 "$repo_root/$path" | awk '{print $1}')"
    printf '%s\0%s\n' "$path" "$file_hash"
  done < <(git -C "$repo_root" ls-files --others --exclude-standard -z | LC_ALL=C sort -z)
} | shasum -a 256 | awk '{print $1}')"
review_cmd=(coderabbit review --agent --uncommitted --include-untracked)

if [[ "$dry_run" -eq 1 ]]; then
  printf 'scope=%s\nbase_commit=%s\nfingerprint=%s\ncommand=' "$scope" "$comparison" "$fingerprint"
  printf '%q ' "${review_cmd[@]}"
  printf '\n'
  exit 0
fi

coderabbit auth status >/dev/null 2>&1 || die "CodeRabbit authentication is not ready"
state_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path coderabbit-cli-review-loop)"
count_file="$state_dir/fresh-${fingerprint}.count"
fresh_count=0
if [[ -f "$count_file" ]]; then
  fresh_count="$(sed -n '1p' "$count_file")"
  [[ "$fresh_count" =~ ^[0-9]+$ ]] || die "invalid fresh-pass state"
fi
(( fresh_count < 3 )) || die "three fresh passes already ran for this exact snapshot"

fresh_root="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-cli-fresh.XXXXXX")"
cleanup() {
  case "$fresh_root" in
    */coderabbit-cli-fresh.*) rm -rf -- "$fresh_root" ;;
    *) printf 'warning: refusing unsafe temporary cleanup: %s\n' "$fresh_root" >&2 ;;
  esac
}
trap cleanup EXIT
fresh_repo="$fresh_root/repository"

git clone --quiet --no-hardlinks --branch "$branch" "$repo_root" "$fresh_repo"
if remote_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null)"; then
  git -C "$fresh_repo" remote set-url origin "$remote_url"
fi

git -C "$fresh_repo" reset --quiet --hard "$comparison"
if ! git -C "$repo_root" diff --quiet "$comparison" --; then
  git -C "$repo_root" diff --binary "$comparison" -- | git -C "$fresh_repo" apply --binary -
fi
while IFS= read -r -d '' path; do
  mkdir -p "$fresh_repo/$(dirname "$path")"
  cp -pP -- "$repo_root/$path" "$fresh_repo/$path"
done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)

(
  cd "$fresh_repo"
  "${review_cmd[@]}"
)
mkdir -p "$state_dir"
printf '%s\n' "$((fresh_count + 1))" > "$count_file"
