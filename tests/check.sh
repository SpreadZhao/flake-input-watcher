#!/usr/bin/env bash
# jq programs intentionally contain literal dollar variables.
# shellcheck disable=SC2016
set -euo pipefail

# All remote queries use a temporary local repository; no network or desktop.
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
watcher="$root/src/flake-input-watcher"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state"
export TEST_REMOTE="$scratch/remote" TEST_LOG="$scratch/events"
mkdir -p "$HOME" "$scratch/bin" "$scratch/checkout with spaces"
real_git=$(command -v git)
export TEST_REAL_GIT="$real_git"
"$real_git" init -q -b main "$TEST_REMOTE"
"$real_git" -C "$TEST_REMOTE" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m old
old=$("$real_git" -C "$TEST_REMOTE" rev-parse HEAD)
"$real_git" -C "$TEST_REMOTE" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m new
new=$("$real_git" -C "$TEST_REMOTE" rev-parse HEAD)
"$real_git" -C "$TEST_REMOTE" branch nixos-unstable
"$real_git" -C "$TEST_REMOTE" -c user.name=Test -c user.email=test@example.invalid tag -a v1 -m tag
mkdir -p "$TEST_LOG"
cat >"$scratch/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e "$TEST_LOG/block" ]]; then
    touch "$TEST_LOG/started"
    while [[ -e "$TEST_LOG/block" ]]; do sleep 0.05; done
fi
if [[ $* == *broken.invalid* ]]; then exit 1; fi
printf '%s\n' "$*" >>"$TEST_LOG/queries"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ ${args[i]} == https://* ]]; then args[i]=$TEST_REMOTE; fi
done
exec "$TEST_REAL_GIT" "${args[@]}"
EOF
cat >"$scratch/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e "$TEST_LOG/notify-fail" ]] || exit 1
printf '%s\n' "$*" >>"$TEST_LOG/notifications"
EOF
cat >"$scratch/hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e "$TEST_LOG/hook-fail" ]] || exit 1
[[ $PWD == "$FLAKE_PATH" ]] || exit 1
if IFS= read -r unexpected; then
    printf 'hook received unexpected stdin: %s\n' "$unexpected" >&2
    exit 1
fi
jq -cn '{path:env.FLAKE_PATH,input:env.FLAKE_INPUT_NAME,source:env.FLAKE_INPUT_SOURCE,
    ref:env.FLAKE_INPUT_REF,old:env.FLAKE_LOCKED_REV,new:env.FLAKE_REMOTE_REV}' >>"$TEST_LOG/hooks"
EOF
sed -i "1c#!$BASH" "$scratch/bin/"* "$scratch/hook"
chmod +x "$scratch/bin/"* "$scratch/hook"
export PATH="$scratch/bin:$PATH"
flake="$scratch/checkout with spaces"
config="$scratch/config.json"
jq -n --arg old "$old" '
    {version:7,root:"root",nodes:{root:{inputs:{nixpkgs:"nixpkgs_2",head:"default",tag:"tag",
        alias:["nixpkgs"],disabled:"disabled",pin:"pin",archive:"archive",cycle:["cycle"]}},
        nixpkgs_2:{original:{type:"github",owner:"NixOS",repo:"nixpkgs",ref:"nixos-unstable"},locked:{rev:$old}},
        default:{flake:false,original:{type:"github",owner:"test",repo:"default"},locked:{rev:$old}},
        tag:{original:{type:"git",url:"https://test.invalid/repo",ref:"refs/tags/v1"},locked:{rev:$old}},
        disabled:{original:{type:"git",url:"https://test.invalid/repo",ref:"main"},locked:{rev:$old}},
        pin:{original:{type:"github",owner:"test",repo:"pin",rev:$old},locked:{rev:$old}},
        archive:{original:{type:"tarball",url:"https://test.invalid/a.tar.gz"},locked:{narHash:"hash"}}
    }}
' >"$flake/flake.lock"
jq -n --arg path "$flake" --arg hook "$scratch/hook" '
    {flakePath:$path,inputs:{disabled:{enable:false}},hooks:{notify:{type:"notify"},log:{type:"shell",command:$hook}},
     rules:[{inputs:["*"],hooks:["notify","log"]},{inputs:["nixpkgs"],hooks:["log"]}],requestTimeout:2,hookTimeout:2}
' >"$config"

assert() { if ! "$@" >/dev/null; then
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
fi; }
run() { "$watcher" check --config "$config" >"$scratch/result.json" 2>"$scratch/stderr"; }
run_failure() { if run; then
	printf 'expected failure\n' >&2
	exit 1
fi; }
count() { if [[ -f $1 ]]; then wc -l <"$1"; else printf 0; fi; }
edit_lock() {
	jq "$@" "$flake/flake.lock" >"$scratch/lock.next"
	mv "$scratch/lock.next" "$flake/flake.lock"
}
edit_config() {
	jq "$@" "$config" >"$scratch/config.next"
	mv "$scratch/config.next" "$config"
}

# Cyclic follows is isolated; disabled, pinned and unsupported entries stay explicit.
"$watcher" list-inputs --config "$config" >"$scratch/list.json"
assert jq -e 'any(.[]; .input=="cycle" and .status=="error")' "$scratch/list.json"
assert jq -e 'any(.[]; .input=="disabled" and .reason=="disabled")' "$scratch/list.json"
assert jq -e 'any(.[]; .input=="pin" and .reason=="pinned revision")' "$scratch/list.json"
run_failure
assert jq -e '.failures==1 and ([.inputs[] | select(.status=="update")] | length)==4' "$scratch/result.json"
assert test "$(count "$TEST_LOG/hooks")" = 4
assert jq -se --arg new "$new" --arg path "$flake" 'length==4 and all(.[]; .new==$new and .path==$path)' "$TEST_LOG/hooks"
assert jq -se --arg old "$old" 'any(.[]; .input=="nixpkgs" and .ref=="nixos-unstable" and
    .source=="https://github.com/NixOS/nixpkgs.git" and .old==$old)' "$TEST_LOG/hooks"
assert test "$(count "$TEST_LOG/queries")" = 4
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 1
edit_lock 'del(.nodes.root.inputs.cycle)'
# Legacy action history is ignored, even when malformed, and never rewritten.
assert test ! -e "$XDG_STATE_HOME/flake-input-watcher/state.json"
printf 'legacy state is no longer used\n' >"$XDG_STATE_HOME/flake-input-watcher/state.json"
cp "$XDG_STATE_HOME/flake-input-watcher/state.json" "$scratch/legacy-state"
run
assert test "$(count "$TEST_LOG/hooks")" = 8
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 2
assert cmp "$scratch/legacy-state" "$XDG_STATE_HOME/flake-input-watcher/state.json"

# Dry-run on a fresh state directory causes neither hook execution nor state writes.
XDG_STATE_HOME="$scratch/dry-state" "$watcher" check --dry-run --config "$config" >"$scratch/dry.json" 2>/dev/null
assert test ! -e "$scratch/dry-state"
assert test "$(count "$TEST_LOG/hooks")" = 8
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 2

# HEAD, branch, short tag and peeled tag all resolve; every update runs its hooks.
"$real_git" -C "$TEST_REMOTE" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m newer
newer=$("$real_git" -C "$TEST_REMOTE" rev-parse HEAD)
"$real_git" -C "$TEST_REMOTE" branch -f nixos-unstable
edit_lock '.nodes.tag.original.ref="v1"'
run
assert test "$(count "$TEST_LOG/hooks")" = 12
assert jq -se --arg newer "$newer" --arg tag "$new" \
    '.[-4:] | all(.[]; if .input=="tag" then .new==$tag else .new==$newer end)' "$TEST_LOG/hooks"
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 3

# Hook failures do not prevent notifications; all hooks run again next time.
edit_config '.hooks.retry=.hooks.log | .rules += [{inputs:["nixpkgs"],hooks:["retry"]}]'
touch "$TEST_LOG/hook-fail"
run_failure
assert jq -e '.failures==5' "$scratch/result.json"
assert test "$(count "$TEST_LOG/hooks")" = 12
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 4
rm "$TEST_LOG/hook-fail"
run
assert test "$(count "$TEST_LOG/hooks")" = 17
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 5

# Notification failure is isolated; successful shell hooks also repeat next time.
edit_config '.hooks.second={type:"notify"} | .rules += [{inputs:["head"],hooks:["second"]}]'
touch "$TEST_LOG/notify-fail"
run_failure
assert jq -e '.failures==1' "$scratch/result.json"
assert test "$(count "$TEST_LOG/hooks")" = 22
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 5
rm "$TEST_LOG/notify-fail"
run
assert test "$(count "$TEST_LOG/hooks")" = 27
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 6

# One unreachable input does not stop other queries; explicit refs/heads also work.
edit_lock --arg old "$old" '.nodes.root.inputs.broken="broken" |
    .nodes.broken={original:{type:"git",url:"https://broken.invalid/repo"},locked:{rev:$old}} |
    .nodes.disabled.original.ref="refs/heads/main"'
edit_config '.inputs.disabled.enable=true'
run_failure
assert jq -e '.failures==1 and any(.inputs[]; .input=="disabled" and .status=="update")' "$scratch/result.json"
assert test "$(count "$TEST_LOG/hooks")" = 33
edit_lock 'del(.nodes.root.inputs.broken)'

# Lock catching up eliminates updates. Adding/removing inputs is picked up each run.
edit_lock --arg rev "$newer" --arg tag "$new" '.nodes.nixpkgs_2.locked.rev=$rev |
    .nodes.default.locked.rev=$rev | .nodes.disabled.locked.rev=$rev | .nodes.tag.locked.rev=$tag'
run
assert jq -e 'all(.inputs[]; .status != "update")' "$scratch/result.json"
assert test "$(count "$TEST_LOG/hooks")" = 33
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = 7
edit_lock --arg old "$old" '.nodes.root.inputs.added="added" |
    .nodes.added={original:{type:"git",url:"https://test.invalid/repo",ref:"main"},locked:{rev:$old}}'
run
assert test "$(count "$TEST_LOG/hooks")" = 34
edit_lock 'del(.nodes.root.inputs.added)'
run
assert jq -e 'all(.inputs[]; .input != "added")' "$scratch/result.json"

# Concurrent calls skip before querying; a lock is not inherited by shell hooks.
touch "$TEST_LOG/block"
"$watcher" check --config "$config" >"$scratch/concurrent.json" 2>"$scratch/concurrent.err" &
pid=$!
for ((i = 0; i < 100; i++)); do
	[[ ! -e "$TEST_LOG/started" ]] || break
	sleep 0.02
done
assert test -e "$TEST_LOG/started"
run
assert rg -q 'another check is running' "$scratch/stderr"
rm "$TEST_LOG/block"
wait "$pid"

# Follows can traverse a node and resolve another follows alias.
edit_lock --arg old "$old" '.nodes.root.inputs.container="container" |
    .nodes.container={original:{type:"git",url:"https://test.invalid/repo",rev:$old},
        locked:{rev:$old},inputs:{child:["head"]}} |
    .nodes.root.inputs.nested=["container","child"]'
run
assert jq -e 'any(.inputs[]; .input=="nested" and .status=="current")' "$scratch/result.json"

# Request and hook timeouts do not prevent later work or subsequent checks.
touch "$TEST_LOG/block"
run_failure
rm "$TEST_LOG/block"
assert jq -e '.failures >= 1 and any(.inputs[]; .status=="error")' "$scratch/result.json"
cat >"$scratch/slow-hook" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
sed -i "1c#!$BASH" "$scratch/slow-hook"
chmod +x "$scratch/slow-hook"
edit_config --arg command "$scratch/slow-hook" '.hooks.slow={type:"shell",command:$command} |
    .rules += [{inputs:["head"],hooks:["slow"]}] | .hookTimeout=1'
edit_lock --arg old "$old" '.nodes.default.locked.rev=$old'
run_failure
assert jq -e '.failures==1' "$scratch/result.json"
edit_config --arg command "$scratch/hook" '.hooks.slow.command=$command'
before=$(count "$TEST_LOG/hooks")
run
assert test "$(count "$TEST_LOG/hooks")" = "$((before + 3))"

# Rebinding only a selected input does not notify other updates.
edit_config '.rules=[{inputs:["nixpkgs"],hooks:["notify"]}]'
notifications=$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")
run
assert test "$(rg -c 'Flake inputs 有更新' "$TEST_LOG/notifications")" = "$notifications"

# Undefined hooks fail before making any upstream queries.
edit_config '.rules=[{inputs:["*"],hooks:["missing"]}]'
queries=$(count "$TEST_LOG/queries")
run_failure
assert test "$(count "$TEST_LOG/queries")" = "$queries"
printf 'flake-input-watcher: all tests passed\n'
