#!/bin/zsh
set -euo pipefail

MODE="ensure"
CWD=""
MESSAGE=""
PUSH_AFTER_COMMIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --cwd)
      CWD="$2"
      shift 2
      ;;
    --message)
      MESSAGE="$2"
      shift 2
      ;;
    --push)
      PUSH_AFTER_COMMIT=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CWD" ]]; then
  echo "Working directory is required" >&2
  exit 1
fi

cd "$CWD"

slugify() {
  python3 - <<'PY' "$1"
import re, sys
value = sys.argv[1].strip().lower()
value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
print(value or "project")
PY
}

json_print() {
  python3 - <<'PY' "$@"
import json, sys
payload = {
    "gitRoot": sys.argv[1],
    "branch": sys.argv[2],
    "initialized": sys.argv[3] == "1",
    "commitCreated": sys.argv[4] == "1",
    "commitHash": sys.argv[5] or None,
    "pushed": sys.argv[6] == "1",
    "remote": sys.argv[7] or None,
    "pushError": sys.argv[8] or None,
}
print(json.dumps(payload))
PY
}

ensure_identity() {
  local current_name current_email
  current_name="$(git config user.name || true)"
  current_email="$(git config user.email || true)"
  if [[ -z "$current_name" ]]; then
    git config user.name "Codex Relay"
  fi
  if [[ -z "$current_email" ]]; then
    git config user.email "codex-relay@local"
  fi
}

ensure_repo_and_branch() {
  local initialized=0

  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    git init -b main >/dev/null
    initialized=1
  fi

  local git_root
  git_root="$(git rev-parse --show-toplevel)"
  cd "$git_root"
  ensure_identity

  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    git add -A
    if git diff --cached --quiet; then
      git commit --allow-empty -m "Initial scaffold" >/dev/null
    else
      git commit -m "Initial scaffold" >/dev/null
    fi
  fi

  if ! git show-ref --verify --quiet refs/heads/main; then
    git branch main >/dev/null
  fi

  local current_branch
  current_branch="$(git branch --show-current || true)"
  local default_side_branch="codex/$(slugify "$(basename "$git_root")")"

  if [[ "$current_branch" == codex/* ]]; then
    :
  elif git show-ref --verify --quiet "refs/heads/$default_side_branch"; then
    git checkout "$default_side_branch" >/dev/null
  else
    git checkout -b "$default_side_branch" >/dev/null
  fi

  current_branch="$(git branch --show-current || true)"
  printf '%s\n%s\n%s\n' "$initialized" "$git_root" "$current_branch"
}

ENSURE_RESULT="$(ensure_repo_and_branch)"
INITIALIZED="$(printf '%s\n' "$ENSURE_RESULT" | sed -n '1p')"
GIT_ROOT="$(printf '%s\n' "$ENSURE_RESULT" | sed -n '2p')"
BRANCH_NAME="$(printf '%s\n' "$ENSURE_RESULT" | sed -n '3p')"

if ! git -C "$GIT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Failed to resolve git root" >&2
  exit 1
fi

if [[ ! -d "$GIT_ROOT/.git" ]]; then
  echo "Failed to initialize git repo" >&2
  exit 1
fi

if [[ "$MODE" == "ensure" ]]; then
  REMOTE_NAME="$(git -C "$GIT_ROOT" remote | head -n 1 || true)"
  json_print "$GIT_ROOT" "$BRANCH_NAME" "$INITIALIZED" "0" "" "0" "$REMOTE_NAME" ""
  exit 0
fi

if [[ "$MODE" != "sync" ]]; then
  echo "Unsupported mode: $MODE" >&2
  exit 1
fi

if [[ -z "$MESSAGE" ]]; then
  echo "Commit message is required for sync mode" >&2
  exit 1
fi

cd "$GIT_ROOT"
git add -A

COMMIT_CREATED=0
COMMIT_HASH=""
if ! git diff --cached --quiet; then
  git commit -m "$MESSAGE" >/dev/null
  COMMIT_CREATED=1
  COMMIT_HASH="$(git rev-parse HEAD)"
fi

PUSHED=0
REMOTE_NAME="$(git remote | head -n 1 || true)"
PUSH_ERROR=""
if [[ "$COMMIT_CREATED" == "1" && "$PUSH_AFTER_COMMIT" == "1" && -n "$REMOTE_NAME" ]]; then
  PUSH_OUTPUT="$(git push -u "$REMOTE_NAME" "$BRANCH_NAME" 2>&1)" || PUSH_ERROR="$PUSH_OUTPUT"
  if [[ -z "$PUSH_ERROR" ]] && git ls-remote --exit-code --heads "$REMOTE_NAME" "$BRANCH_NAME" >/dev/null 2>&1; then
    PUSHED=1
  elif [[ -z "$PUSH_ERROR" ]]; then
    PUSH_ERROR="Push finished, but the remote branch could not be verified."
  fi
elif [[ "$COMMIT_CREATED" == "1" && "$PUSH_AFTER_COMMIT" == "1" && -z "$REMOTE_NAME" ]]; then
  PUSH_ERROR="No git remote is configured for this repository."
fi

json_print "$GIT_ROOT" "$BRANCH_NAME" "$INITIALIZED" "$COMMIT_CREATED" "$COMMIT_HASH" "$PUSHED" "$REMOTE_NAME" "$PUSH_ERROR"
