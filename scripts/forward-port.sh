#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: forward_port.sh [options] <commit-hash>

Creates a branch and attempts to apply the changes from <commit-hash>
onto the current workspace (forward-porting a historical fix).

Options:
  --dry-run    Do everything except modify the working tree or commit
  -h, --help   Show this help

Example:
  ./scripts/forward_port.sh df5f12318313
  ./scripts/forward_port.sh --dry-run df5f12318313

USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing  (flags may appear before OR after the commit hash)
# ---------------------------------------------------------------------------
DRY_RUN=0
COMMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "Unknown option: $1"; usage; exit 1 ;;
    *)           COMMIT="$1"; shift ;;
  esac
done

if [[ -z "$COMMIT" ]]; then
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate commit
# ---------------------------------------------------------------------------
if ! git rev-parse --verify "$COMMIT" >/dev/null 2>&1; then
  echo "error: commit '$COMMIT' not found"
  exit 2
fi

# Warn if this is a merge commit (diff will only cover first parent)
if git rev-parse --verify "${COMMIT}^2" >/dev/null 2>&1; then
  echo "Warning: '$COMMIT' is a merge commit; diff is against first parent only."
fi

# ---------------------------------------------------------------------------
# Patch file – cleaned up automatically on exit
# ---------------------------------------------------------------------------
PATCH_FILE=$(mktemp "/tmp/${COMMIT}-XXXXXX.patch")
trap 'rm -f "$PATCH_FILE"' EXIT

PARENT=$(git rev-parse "${COMMIT}^1")
echo "Generating patch: ${PARENT}..${COMMIT} -> ${PATCH_FILE}"
git --no-pager diff "${PARENT}" "${COMMIT}" > "$PATCH_FILE"

# ---------------------------------------------------------------------------
# Branch management
# ---------------------------------------------------------------------------
BRANCH="forward-port-${COMMIT}"

if [[ $DRY_RUN -eq 0 ]]; then
  if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    echo "Branch '${BRANCH}' already exists — checking it out."
    git checkout "$BRANCH"
  else
    echo "Creating branch: ${BRANCH}"
    git checkout -b "$BRANCH"
  fi
else
  echo "Dry-run: skipping branch creation (would use '${BRANCH}')"
fi

# ---------------------------------------------------------------------------
# Show what the patch touches
# ---------------------------------------------------------------------------
echo ""
echo "Files changed in the patch:"
git apply --numstat "$PATCH_FILE" || echo "Warning: could not read patch stats (patch may be empty or malformed)"

# ---------------------------------------------------------------------------
# Helper: report any leftover .rej files
# ---------------------------------------------------------------------------
report_rejects() {
  local rejects
  rejects=$(find . -name "*.rej" 2>/dev/null | sort)
  if [[ -n "$rejects" ]]; then
    echo ""
    echo "WARNING: The following reject files need manual resolution:"
    echo "$rejects"
  fi
}

# ---------------------------------------------------------------------------
# In dry-run mode just check whether the patch would apply and exit
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  echo "Dry-run: checking patch with 'git apply --check'"
  if git apply --check "$PATCH_FILE" 2>&1; then
    echo "Dry-run: patch would apply cleanly."
  else
    echo "Dry-run: patch would NOT apply cleanly (conflicts expected)."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Attempt 1: three-way merge apply
# ---------------------------------------------------------------------------
echo ""
echo "Attempting three-way apply (git apply --3way)"
if git apply --3way "$PATCH_FILE"; then
  echo "Patch applied cleanly (3-way)."
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "Forward-port commit ${COMMIT}"
    echo "Committed on branch ${BRANCH}"
  else
    echo "No changes to commit (patch was already applied?)."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Attempt 2: reject mode (applies what it can, leaves .rej for the rest)
# ---------------------------------------------------------------------------
echo ""
echo "3-way apply failed. Trying reject mode (git apply --reject --whitespace=fix)"
# git apply --reject exits 0 even when some hunks were rejected, so we cannot
# rely on the exit code to judge completeness – we check for .rej files below.
git apply --reject --whitespace=fix "$PATCH_FILE" || true

report_rejects

echo ""
echo "Files after partial apply:"
git status --porcelain

git add -A || true
if ! git diff --cached --quiet; then
  git commit -m "Forward-port (partial) ${COMMIT}" || true
  echo "Committed partial application on branch ${BRANCH}"
else
  echo "No changes staged to commit."
fi

echo ""
echo "If .rej files exist above, resolve them manually, then:"
echo "  git add <files> && git commit --amend"
exit 0