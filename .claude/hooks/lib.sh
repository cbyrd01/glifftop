# Shared helpers for the Claude Code hooks. Source it; don't run it.
# Each hook reads its JSON payload from stdin once into $payload.

payload=$(cat)

# fields KEY[.KEY...]... — print one `name='value'` shell assignment per key, for eval.
# Dots in a key become underscores. Absent keys are empty; booleans are true/false.
# One python3 start per call, however many keys.
fields() {
    printf '%s' "$payload" | python3 -I -c '
import json, shlex, sys
data = json.load(sys.stdin)
for path in sys.argv[1:]:
    value = data
    for key in path.split("."):
        value = value.get(key) if isinstance(value, dict) else None
    if isinstance(value, bool):
        value = str(value).lower()
    print(path.replace(".", "_") + "=" + shlex.quote("" if value is None else str(value)))
' "$@"
}

# cd_project — cd to the top of the checkout the session works in: the payload's `cwd`
# (set it first with `fields cwd`), so a git worktree is used rather than the main checkout.
cd_project() {
    cd "${cwd:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || return 1
    top=$(git rev-parse --show-toplevel 2>/dev/null) && cd "$top"
    return 0
}

# strip_color — remove ANSI color codes from stdin.
strip_color() { sed 's/\x1b\[[0-9;]*m//g'; }
