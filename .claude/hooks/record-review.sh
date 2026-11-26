#!/bin/sh
# Record that /simplify or /code-review ran, with the HEAD it ran at, in the git dir.
# scripts/git-hooks/pre-commit reads the record to gate Claude's commits of code, and
# post-commit clears it.
# Usage: record-review.sh skill    PostToolUse, matcher Skill
#        record-review.sh prompt   UserPromptSubmit (a typed /simplify is not a Skill call)
. "$(dirname "$0")/lib.sh"

# Most prompts and skills aren't reviews: skip the JSON parse unless one could be.
case "$payload" in *simplify* | *code-review*) ;; *) exit 0 ;; esac

case "$1" in
    skill)
        eval "$(fields cwd tool_input.skill)"
        skill=$tool_input_skill
        ;;
    prompt)
        eval "$(fields cwd prompt)"
        skill=$(printf '%s\n' "$prompt" | sed -n '1s|^/\([a-z-]*\).*|\1|p')
        ;;
esac
case "$skill" in
    simplify | code-review) ;;
    *) exit 0 ;;
esac

cd_project || exit 0
head=$(git rev-parse HEAD 2>/dev/null) || exit 0
echo "$skill $head" >>"$(git rev-parse --absolute-git-dir)/claude-reviews"
