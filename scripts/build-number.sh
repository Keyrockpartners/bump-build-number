#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "build-number-action: $*" >&2
  exit 1
}

KEY="${INPUT_KEY:-}"
BRANCH="${INPUT_BRANCH:-build-numbers}"
FILE_PATH="${INPUT_FILE:-build-numbers.json}"
TOKEN="${INPUT_GITHUB_TOKEN:-}"
COMMITTER_NAME="${INPUT_COMMITTER_NAME:-github-actions[bot]}"
COMMITTER_EMAIL="${INPUT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
MAX_ATTEMPTS="${INPUT_MAX_ATTEMPTS:-10}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

[[ -n "$KEY" ]] || fail "input 'key' is required"
[[ -n "$BRANCH" ]] || fail "input 'branch' must not be empty"
[[ -n "$FILE_PATH" ]] || fail "input 'file' must not be empty"
[[ -n "$TOKEN" ]] || fail "input 'github-token' is required"
[[ -n "$REPOSITORY" ]] || fail "GITHUB_REPOSITORY is not set"
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] && [[ "$MAX_ATTEMPTS" -ge 1 ]] || fail "input 'max-attempts' must be a positive integer"

git check-ref-format "refs/heads/${BRANCH}" >/dev/null 2>&1 || fail "input 'branch' is not a valid branch name: ${BRANCH}"

case "$FILE_PATH" in
  /*) fail "input 'file' must be relative to the storage branch root" ;;
  */|''|.git|.git/*|*/.git|*/.git/*) fail "input 'file' must be a regular file path outside .git" ;;
esac
case "/${FILE_PATH}/" in
  *'/../'*|*'/./'*) fail "input 'file' must not contain . or .. path components" ;;
esac

if [[ "$SERVER_URL" != https://* && "$SERVER_URL" != http://* ]]; then
  fail "GITHUB_SERVER_URL must start with http:// or https://"
fi

# Hide the token if GitHub renders command output.
echo "::add-mask::${TOKEN}"
AUTH_HEADER="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
echo "::add-mask::${AUTH_HEADER}"

REPO_URL="${SERVER_URL%/}/${REPOSITORY}.git"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
git init --quiet
git remote add origin "$REPO_URL"
git config user.name "$COMMITTER_NAME"
git config user.email "$COMMITTER_EMAIL"

# Use an authorization header instead of writing the token into the remote URL.
git_auth() {
  git -c "http.extraheader=AUTHORIZATION: basic ${AUTH_HEADER}" "$@"
}

write_outputs() {
  local number="$1"
  local existed="$2"
  {
    echo "build-number=${number}"
    echo "number=${number}"
    echo "existed=${existed}"
  } >> "$OUTPUT_FILE"
  echo "build-number-action: build-number=${number}, existed=${existed}"
}

prepare_storage_branch() {
  local fetch_ok=0
  local ls_remote_status=0

  if git_auth ls-remote --quiet --exit-code --heads origin "$BRANCH" >/dev/null; then
    git_auth fetch --quiet --no-tags --depth=1 origin "refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"
    fetch_ok=1
  else
    ls_remote_status=$?
    # git ls-remote --exit-code returns 2 when no matching ref exists.
    if [[ "$ls_remote_status" -ne 2 ]]; then
      fail "could not query storage branch ${BRANCH} from ${REPOSITORY}"
    fi
  fi

  if [[ "$fetch_ok" -eq 1 ]]; then
    git checkout --quiet -B build-number-work "refs/remotes/origin/${BRANCH}"
    git reset --quiet --hard "refs/remotes/origin/${BRANCH}"
    git clean --quiet -fdx
  else
    if git show-ref --verify --quiet refs/heads/build-number-work; then
      git checkout --quiet --detach
      git branch --quiet -D build-number-work
    fi
    git checkout --quiet --orphan build-number-work
    git rm -r --quiet --ignore-unmatch . >/dev/null 2>&1 || true
    find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  fi
}

allocate_or_lookup() {
  KEY="$KEY" FILE_PATH="$FILE_PATH" python3 <<'PY'
import json
import os
import pathlib
import sys

key = os.environ["KEY"]
file_path = pathlib.Path(os.environ["FILE_PATH"])

if file_path.exists():
    try:
        raw = file_path.read_text(encoding="utf-8").strip()
        data = json.loads(raw) if raw else {}
    except Exception as exc:
        print(f"invalid JSON in {file_path}: {exc}", file=sys.stderr)
        sys.exit(2)
else:
    data = {}

# Preferred schema:
# {
#   "next": 2,
#   "keys": {
#     "some-key": 1
#   }
# }
# A legacy flat {"key": 1} file is also accepted and migrated.
if isinstance(data, dict) and isinstance(data.get("keys"), dict):
    keys = data["keys"]
    try:
        next_number = int(data.get("next", 1))
    except (TypeError, ValueError):
        next_number = 1
elif isinstance(data, dict):
    keys = data
    next_number = 1
else:
    print(f"{file_path} must contain a JSON object", file=sys.stderr)
    sys.exit(2)

normalized_keys = {}
max_number = 0
for existing_key, value in keys.items():
    try:
        number = int(value)
    except (TypeError, ValueError):
        print(f"build number for key {existing_key!r} is not an integer", file=sys.stderr)
        sys.exit(2)
    normalized_keys[str(existing_key)] = number
    max_number = max(max_number, number)

keys = normalized_keys
if key in keys:
    print(f"exists\t{keys[key]}")
    sys.exit(0)

number = max(next_number, max_number + 1, 1)
keys[key] = number
file_path.parent.mkdir(parents=True, exist_ok=True)
with file_path.open("w", encoding="utf-8") as fh:
    json.dump({"next": number + 1, "keys": keys}, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(f"created\t{number}")
PY
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "build-number-action: attempt ${attempt}/${MAX_ATTEMPTS}"
  prepare_storage_branch

  result="$(allocate_or_lookup)"
  status="${result%%$'\t'*}"
  number="${result#*$'\t'}"

  if [[ "$status" == "exists" ]]; then
    write_outputs "$number" "true"
    exit 0
  fi

  if [[ "$status" != "created" || -z "$number" ]]; then
    fail "unexpected allocator result: ${result}"
  fi

  git add -- "$FILE_PATH"
  if git diff --cached --quiet; then
    # Defensive fallback: if no file changed, retry. This should not normally happen.
    sleep 1
    continue
  fi

  git commit --quiet -m "Record build number ${number}" -m "Key: ${KEY}"

  if git_auth push --quiet origin "HEAD:refs/heads/${BRANCH}"; then
    write_outputs "$number" "false"
    exit 0
  fi

  echo "build-number-action: push failed, another job may have updated ${BRANCH}; retrying" >&2
  sleep "$(( attempt < 5 ? attempt : 5 ))"
done

fail "could not update ${BRANCH} after ${MAX_ATTEMPTS} attempts"
