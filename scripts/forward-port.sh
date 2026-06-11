#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: forward_port.sh [options] <commit-hash>

Creates a branch and cherry-picks <commit-hash> onto the current workspace
(forward-porting a historical fix).

If conflicts arise, the script pauses and opens them in your editor so you
can resolve them interactively before committing.

Options:
  --dry-run    Check whether the cherry-pick would conflict without touching
               the working tree or creating a branch
  -h, --help   Show this help

Example:
  ./scripts/forward_port.sh df5f12318313
  ./scripts/forward_port.sh --dry-run df5f12318313

USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing (flags may appear before OR after the commit hash)
# ---------------------------------------------------------------------------
DRY_RUN=0
COMMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "Unknown option: $1"; usage; exit 1 ;;
    *)          COMMIT="$1"; shift ;;
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

# Resolve to the full hash so branch names and messages are always consistent
COMMIT=$(git rev-parse "$COMMIT")

# Warn on merge commits — cherry-pick will use -m 1 (first parent) automatically
if git rev-parse --verify "${COMMIT}^2" >/dev/null 2>&1; then
  echo "Warning: '$COMMIT' is a merge commit; cherry-picking against first parent only."
  CHERRY_PICK_EXTRA="-m 1"
else
  CHERRY_PICK_EXTRA=""
fi

BRANCH="forward-port-${COMMIT}"

# ---------------------------------------------------------------------------
# Dry-run: use a temporary worktree so the real tree is never touched
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  TMPDIR_WT=$(mktemp -d)
  trap 'git worktree remove --force "$TMPDIR_WT" 2>/dev/null; rm -rf "$TMPDIR_WT"' EXIT

  echo "Dry-run: creating temporary worktree at ${TMPDIR_WT}"
  git worktree add --detach "$TMPDIR_WT" HEAD >/dev/null 2>&1

  echo "Dry-run: attempting cherry-pick in temporary worktree"
  if (
    cd "$TMPDIR_WT"
    # shellcheck disable=SC2086
    git cherry-pick --no-commit $CHERRY_PICK_EXTRA "$COMMIT" >/dev/null 2>&1
  ); then
    echo "Dry-run: cherry-pick would apply cleanly — no conflicts expected."
  else
    echo "Dry-run: cherry-pick would produce conflicts."
    echo "         Run without --dry-run to resolve them interactively."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Branch management
# ---------------------------------------------------------------------------
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  echo "Branch '${BRANCH}' already exists — checking it out."
  git checkout "$BRANCH"
else
  echo "Creating branch: ${BRANCH}"
  git checkout -b "$BRANCH"
fi

# ---------------------------------------------------------------------------
# Show what the commit touches
# ---------------------------------------------------------------------------
PARENT=$(git rev-parse "${COMMIT}^1")
echo ""
echo "Files changed in this commit:"
git --no-pager diff --stat "${PARENT}" "${COMMIT}"

# ---------------------------------------------------------------------------
# Cherry-pick (no auto-commit so we control the commit message)
# ---------------------------------------------------------------------------
echo ""
echo "Attempting cherry-pick --no-commit (strategy: recursive, patience diff)"

# shellcheck disable=SC2086
if git cherry-pick --no-commit --strategy=recursive -X patience $CHERRY_PICK_EXTRA "$COMMIT"; then
  # Clean apply — stage only the files that were part of the original commit,
  # not any pre-existing untracked files in the repo.
  CHANGED_FILES=$(git --no-pager diff --name-only "${PARENT}" "${COMMIT}")
  echo ""
  echo "Cherry-pick applied cleanly. Staging only:"
  echo "$CHANGED_FILES"
  # shellcheck disable=SC2086
  git add $CHANGED_FILES
  git commit -m "Forward-port commit ${COMMIT}"
  echo ""
  echo "Done. Committed on branch '${BRANCH}'."
  exit 0
fi

# ---------------------------------------------------------------------------
# Conflicts detected — open editor for interactive resolution
# ---------------------------------------------------------------------------
CONFLICTED=$(git diff --name-only --diff-filter=U)

echo ""
echo "Cherry-pick produced conflicts in:"
echo "$CONFLICTED"
echo ""

# Stage the cleanly-applied files now; leave conflicted ones for the user
git --no-pager diff --name-only "${PARENT}" "${COMMIT}" | while read -r f; do
  if ! echo "$CONFLICTED" | grep -qx "$f"; then
    git add "$f" 2>/dev/null || true
  fi
done

EDITOR="${EDITOR:-}"
if [[ -z "$EDITOR" ]]; then
  # Detect a usable editor in order of preference
  for candidate in vim nano vi; do
    if command -v "$candidate" &>/dev/null; then
      EDITOR="$candidate"
      break
    fi
  done
fi

if [[ -n "$EDITOR" && -n "$CONFLICTED" ]]; then
  echo "Opening conflicted files in '${EDITOR}'..."
  echo "Resolve all <<<<<<< / ======= / >>>>>>> markers, then save and quit."
  echo ""
  # shellcheck disable=SC2086
  $EDITOR $CONFLICTED

  echo ""
  echo "After resolving, stage and commit with:"
  echo "  git add ${CONFLICTED}"
  echo "  git commit -m \"Forward-port commit ${COMMIT}\""
else
  echo "No editor found (set \$EDITOR) or no conflicted files left."
  echo ""
  echo "Resolve conflicts manually, then:"
  echo "  git add <resolved-files>"
  echo "  git commit -m \"Forward-port commit ${COMMIT}\""
fi

echo ""
echo "To abort the forward-port entirely:"
echo "  git cherry-pick --abort"
exit 1