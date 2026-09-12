#!/bin/sh
# wt.sh — parallel-orchestration worktree helper.
#
# THE framework for non-blocking parallel work (eliminates the single-writer + one-branch
# bottlenecks): give each work-unit its OWN git worktree on its OWN feature branch, so N
# agents write in parallel with zero collision, and each merges UP independently when its
# fix->verify is green. Pairs with the stateless emulator (ecosim/p5/run.sh = per-invocation
# mktemp work dir) so parallel agents can also run Layer-2 concurrently.
#
# usage:
#   wt.sh add <branch> [base]   # create ../.wt-<branch> on a new <branch> off [base] (default dev)
#   wt.sh list                  # list worktrees
#   wt.sh rm  <branch>          # remove the worktree (branch kept; delete with `git branch -d`)
#
# Each parallel agent is launched with: cd "<repo>/../.wt-<branch>"; work; commit to <branch>.
# When its verify is green: git checkout <base>; git merge --no-ff <branch>; push; wt.sh rm.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WTBASE="$(cd "$REPO/.." && pwd)"
case "${1:-}" in
  add)  [ -n "${2:-}" ] || { echo "usage: wt.sh add <branch> [base]" >&2; exit 1; }
        git -C "$REPO" worktree add -b "$2" "$WTBASE/.wt-$2" "${3:-dev}" ;;
  list) git -C "$REPO" worktree list ;;
  rm)   [ -n "${2:-}" ] || { echo "usage: wt.sh rm <branch>" >&2; exit 1; }
        git -C "$REPO" worktree remove "$WTBASE/.wt-$2" --force ;;
  *)    echo "usage: wt.sh add <branch> [base] | list | rm <branch>" >&2; exit 1 ;;
esac
