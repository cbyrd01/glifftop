#!/usr/bin/env bash
# Points git at the repo's tracked hooks in scripts/git-hooks. Run once per clone.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath scripts/git-hooks
echo "git hooks: core.hooksPath = scripts/git-hooks"
