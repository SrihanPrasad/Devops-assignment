#!/usr/bin/env bash
# =============================================================================
# TASK 3 - Clone a remote git repo and upload ALL of its files to an S3 bucket
#
# Usage:
#   ./scripts/git-to-s3.sh <repo-url> <bucket> [prefix] [branch]
#
# Examples:
#   ./scripts/git-to-s3.sh https://github.com/octocat/Hello-World.git my-bucket
#   ./scripts/git-to-s3.sh https://github.com/me/private.git my-bucket backups/private main
#
# Env (all optional):
#   GIT_TOKEN        personal access token for private HTTPS repos
#   AWS_PROFILE / AWS_REGION / standard AWS credentials
#   INCLUDE_GIT=1    also upload the .git directory (default: skip it)
#   DELETE=1         remove objects from S3 that no longer exist in the repo
#
# Needs: git, aws cli v2 (configured: `aws configure` or env/instance role)
# =============================================================================
set -euo pipefail

usage() { sed -n '2,19p' "$0"; exit 1; }
[ $# -ge 2 ] || usage

REPO_URL="$1"
BUCKET="$2"
PREFIX="${3:-}"
BRANCH="${4:-}"

command -v git >/dev/null || { echo "ERROR: git not installed" >&2; exit 1; }
command -v aws >/dev/null || { echo "ERROR: aws cli not installed" >&2; exit 1; }

PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"
DEST="s3://${BUCKET}${PREFIX:+/$PREFIX}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT          # always clean up the clone

log() { printf '[git-to-s3] %s\n' "$*"; }

# --- fail early if AWS creds / bucket are wrong --------------------------------
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: AWS credentials not working (run 'aws configure')" >&2; exit 1; }
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || { echo "ERROR: bucket '$BUCKET' does not exist or you have no access" >&2; exit 1; }

# --- clone ---------------------------------------------------------------------
git_args=()
if [ -n "${GIT_TOKEN:-}" ]; then
  # header auth keeps the token out of the URL, process list and .git/config
  auth="$(printf 'x-access-token:%s' "$GIT_TOKEN" | base64 | tr -d '\n')"
  git_args+=(-c "http.extraHeader=Authorization: Basic ${auth}")
fi
clone_args=(--depth 1)
[ -n "$BRANCH" ] && clone_args+=(--branch "$BRANCH")

log "cloning $REPO_URL ${BRANCH:+(branch $BRANCH) }..."
git ${git_args[@]+"${git_args[@]}"} clone "${clone_args[@]}" "$REPO_URL" "$WORKDIR/repo" >/dev/null

COMMIT="$(git -C "$WORKDIR/repo" rev-parse --short HEAD)"
FILE_COUNT="$(find "$WORKDIR/repo" -path "$WORKDIR/repo/.git" -prune -o -type f -print | wc -l | tr -d ' ')"
log "cloned commit $COMMIT - $FILE_COUNT files"

# --- upload --------------------------------------------------------------------
sync_args=()
[ "${INCLUDE_GIT:-0}" = "1" ] || sync_args+=(--exclude ".git/*")
[ "${DELETE:-0}" = "1" ]      && sync_args+=(--delete)

log "uploading to $DEST ..."
aws s3 sync "$WORKDIR/repo" "$DEST" ${sync_args[@]+"${sync_args[@]}"} --only-show-errors

# --- verify --------------------------------------------------------------------
UPLOADED="$(aws s3 ls "$DEST/" --recursive | grep -vc '/\.git/' || true)"
log "done. $UPLOADED objects now under $DEST (repo had $FILE_COUNT files)"
aws s3 ls "$DEST/" | head -20
