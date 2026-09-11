#!/usr/bin/env bash
#
# Host-only tests for vm-claude: no VM, no msb. Sources the script with
# VM_CLAUDE_SOURCED=1 (so main doesn't run) inside throwaway repos and a
# throwaway $HOME, and exercises the host-side functions directly.
#
#   test/run.sh
#
# Must stay bash 3.2 compatible, like vm-claude itself (macOS /bin/bash).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()     { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check()  { local name="$1"; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }

# Git as the tests themselves run it: never execute anything a poisoned repo
# configured, so a setup step can't trip the sentinel and blame vm-claude.
tgit() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c commit.gpgsign=false "$@"; }

# A throwaway $HOME whose global git config signs with a fresh ssh key, exactly
# the shape of a host that has commit.gpgsign=true.
setup_home() {
  export HOME="$T/home"
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  rm -rf "$HOME" && mkdir -p "$HOME"
  ssh-keygen -q -t ed25519 -N '' -C vm-claude-test -f "$HOME/key"
  git config --global user.name "Host User"
  git config --global user.email host@example.com
  git config --global init.defaultBranch main
  git config --global gpg.format ssh
  git config --global user.signingkey "$HOME/key.pub"
  git config --global commit.gpgsign true
  printf 'host@example.com %s\n' "$(cat "$HOME/key.pub")" > "$HOME/allowed_signers"
  git config --global gpg.ssh.allowedSignersFile "$HOME/allowed_signers"
}

# Everything a hostile guest can plant in a guest-writable .git so that host
# git runs it: signing programs, fsmonitor, hooks (both the default dir and a
# hooksPath), editors. Each writes the sentinel and fails.
poison_repo() {
  local repo="$1" evil="$T/evil.sh" h
  printf '#!/bin/sh\necho "ran: $0 $*" >> "%s/sentinel"\nexit 1\n' "$T" > "$evil"
  chmod +x "$evil"
  git -C "$repo" config gpg.ssh.program "$evil"
  git -C "$repo" config gpg.program "$evil"
  git -C "$repo" config gpg.format openpgp
  git -C "$repo" config core.fsmonitor "$evil"
  git -C "$repo" config core.editor "$evil"
  git -C "$repo" config sequence.editor "$evil"
  git -C "$repo" config user.signingkey "attacker-key"
  git -C "$repo" config user.email attacker@example.com
  mkdir -p "$T/evil-hooks"
  git -C "$repo" config core.hooksPath "$T/evil-hooks"
  for h in pre-rebase post-rewrite post-checkout reference-transaction pre-commit post-commit; do
    cp "$evil" "$repo/.git/hooks/$h"
    cp "$evil" "$T/evil-hooks/$h"
  done
}

sentinel_absent() { [ ! -e "$T/sentinel" ]; }

commit_file() {  # $1 repo, $2 file, $3 message
  printf '%s\n' "$3" >> "$1/$2"
  tgit -C "$1" add "$2"
  GIT_AUTHOR_DATE="@1700000000 +0200" tgit -C "$1" commit -q -m "$3"
}

# --- sign-on-exit must not execute guest-planted git config or hooks --------
test_sign_on_exit_ignores_poisoned_repo() {
  setup_home
  rm -f "$T/sentinel"
  local repo="$T/sign-repo"
  rm -rf "$repo" && git init -q "$repo"
  commit_file "$repo" a.txt "base"
  local before
  before="$(tgit -C "$repo" rev-parse HEAD)"

  (
    set -- --sign-on-exit
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_MOUNT="$repo" CLAUDE_VM_CLIP=0
    # shellcheck source=../vm-claude
    . "$ROOT/vm-claude"
    SIGN_ON_EXIT=1
    arm_sign_on_exit 2>/dev/null
    arm_git_audit

    # --- "guest" session: poison .git, make commits incl. a merge, leave a dirty file
    poison_repo "$repo"
    commit_file "$repo" a.txt "first: with a trailing blank line

body line
"
    tgit -C "$repo" checkout -q -b side
    commit_file "$repo" b.txt "side work"
    tgit -C "$repo" checkout -q main
    commit_file "$repo" a.txt "second"
    GIT_AUTHOR_DATE="@1700000500 +0200" tgit -C "$repo" merge -q --no-ff -m "merge side" side
    printf 'uncommitted\n' >> "$repo/a.txt"
    tgit -C "$repo" rev-parse HEAD > "$T/after"
    tgit -C "$repo" log --format='%an|%ae|%at|%B%x00' "${before}..HEAD" > "$T/log-before-sign"
    rm -f "$T/sentinel"
    exit 0   # EXIT trap -> on_exit -> sign_new_commits, as when the VM exits
  ) 2>"$T/sign.err" || true

  local after new
  after="$(cat "$T/after")"
  new="$(tgit -C "$repo" rev-parse HEAD)"

  check "sign: no guest-planted program or hook ran on the host" sentinel_absent
  check "sign: branch was rewritten" [ "$new" != "$after" ]
  check "sign: tree is unchanged" [ "$(tgit -C "$repo" rev-parse "$new^{tree}")" = "$(tgit -C "$repo" rev-parse "$after^{tree}")" ]

  local c all_signed=0
  for c in $(tgit -C "$repo" rev-list "${before}..${new}"); do
    tgit -C "$repo" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen verify-commit "$c" >/dev/null 2>&1 || all_signed=1
  done
  check "sign: every new commit carries a valid host signature" [ "$all_signed" = 0 ]
  check "sign: same number of commits" [ "$(tgit -C "$repo" rev-list --count "${before}..${new}")" = "$(tgit -C "$repo" rev-list --count "${before}..${after}")" ]
  check "sign: merge commit keeps both parents" [ "$(tgit -C "$repo" rev-list --min-parents=2 --count "${before}..${new}")" = 1 ]

  tgit -C "$repo" log --format='%an|%ae|%at|%B%x00' "${before}..${new}" > "$T/log-after-sign"
  check "sign: authors, dates and messages are preserved byte-for-byte" cmp -s "$T/log-before-sign" "$T/log-after-sign"
  check "sign: committer is the host identity, not the repo-local one" \
    [ "$(tgit -C "$repo" log -1 --format=%ce "$new")" = "host@example.com" ]
  check "sign: uncommitted work is left untouched" grep -q '^uncommitted$' "$repo/a.txt"
  check "sign: before is still an ancestor (nothing below it rewritten)" tgit -C "$repo" merge-base --is-ancestor "$before" "$new"
  check "sign: warns that .git gained executable config during the session" grep -q 'executable git config' "$T/sign.err"
}

# --- --worktree creation must not execute guest-planted hooks or filters ----
test_worktree_create_ignores_poisoned_hooks() {
  setup_home
  rm -f "$T/sentinel"
  local repo="$T/wt-repo"
  rm -rf "$repo" && git init -q "$repo"
  commit_file "$repo" a.txt "base"
  poison_repo "$repo"
  rm -f "$T/sentinel"

  (
    set -- --worktree feat
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_CLIP=0
    unset CLAUDE_VM_MOUNT
    cd "$repo"
    . "$ROOT/vm-claude"
    ensure_worktree
  ) >/dev/null 2>&1 || true

  check "worktree: created" [ -e "$repo/.vm-worktrees/feat/.git" ]
  check "worktree: no guest-planted hook or fsmonitor ran on the host" sentinel_absent
}

test_worktree_create_refuses_local_filters() {
  setup_home
  rm -f "$T/sentinel"
  local repo="$T/wt-filter-repo"
  rm -rf "$repo" && git init -q "$repo"
  printf '* filter=evil\n' > "$repo/.gitattributes"
  commit_file "$repo" a.txt "base"
  tgit -C "$repo" add .gitattributes && tgit -C "$repo" commit -q -m attrs
  printf '#!/bin/sh\necho ran >> "%s/sentinel"\ncat\n' "$T" > "$T/smudge.sh" && chmod +x "$T/smudge.sh"
  git -C "$repo" config filter.evil.smudge "$T/smudge.sh"
  git -C "$repo" config filter.evil.clean cat

  local rc=0
  (
    set -- --worktree feat
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_CLIP=0
    unset CLAUDE_VM_MOUNT
    cd "$repo"
    . "$ROOT/vm-claude"
    ensure_worktree
  ) >/dev/null 2>"$T/wt-filter.err" || rc=$?

  check "worktree: refuses when the repo defines local filter drivers" [ "$rc" != 0 ]
  check "worktree: refusal names the offending key" grep -q 'filter.evil.smudge' "$T/wt-filter.err"
  check "worktree: smudge filter never ran" sentinel_absent
  check "worktree: nothing was created" [ ! -e "$repo/.vm-worktrees/feat" ]
}

# --- a normal session: signs, and doesn't cry wolf about pre-existing hooks --
test_sign_on_exit_clean_session_no_warning() {
  setup_home
  local repo="$T/clean-repo"
  rm -rf "$repo" && git init -q "$repo"
  commit_file "$repo" a.txt "base"
  # A hook manager the user set up before the session (husky / pre-commit style).
  git -C "$repo" config core.hooksPath .husky
  mkdir -p "$repo/.husky" && printf '#!/bin/sh\nexit 0\n' > "$repo/.husky/pre-commit"
  printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-push" && chmod +x "$repo/.git/hooks/pre-push"
  local before
  before="$(tgit -C "$repo" rev-parse HEAD)"

  (
    set -- --sign-on-exit
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_MOUNT="$repo" CLAUDE_VM_CLIP=0
    . "$ROOT/vm-claude"
    SIGN_ON_EXIT=1
    arm_sign_on_exit
    arm_git_audit
    commit_file "$repo" a.txt "guest commit"
    exit 0
  ) 2>"$T/clean.err" || true

  local new c
  new="$(tgit -C "$repo" rev-parse HEAD)"
  c="$(tgit -C "$repo" rev-list "${before}..${new}")"
  check "clean: the session's commit is signed" \
    sh -c "git -c core.hooksPath=/dev/null -C '$repo' verify-commit '$c' 2>/dev/null"
  check "clean: announces arming and completion" grep -q 'sign-on-exit: done' "$T/clean.err"
  check "clean: no executable-config warning for hooks that predate the session" \
    sh -c "! grep -q 'executable git config' '$T/clean.err'"
}

test_worktree_refuses_symlinked_holder() {
  setup_home
  local repo="$T/wt-link-repo" elsewhere="$T/elsewhere"
  rm -rf "$repo" "$elsewhere" && git init -q "$repo" && mkdir -p "$elsewhere"
  commit_file "$repo" a.txt "base"
  ln -s "$elsewhere" "$repo/.vm-worktrees"

  local rc=0
  (
    set -- --worktree feat
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_CLIP=0
    unset CLAUDE_VM_MOUNT
    cd "$repo"
    . "$ROOT/vm-claude"
    ensure_worktree
  ) >/dev/null 2>"$T/wt-link.err" || rc=$?

  check "worktree: refuses a symlinked holder dir" [ "$rc" != 0 ]
  check "worktree: nothing written through the symlink" [ ! -e "$elsewhere/feat" ]
}

# --- ~/.claude config bundle -------------------------------------------------

# A host ~/.claude with every shape the bundle builder has to get right.
setup_config_fixture() {
  setup_home
  local C="$HOME/.claude" A="$HOME/.agents/skills"
  mkdir -p "$C/skills/real" "$C/agents" "$C/hooks/big" \
    "$A/good" "$A/my skill" "$A/other" "$A/withlinks"
  echo guide > "$C/CLAUDE.md"
  echo real > "$C/skills/real/SKILL.md"
  echo good > "$A/good/SKILL.md"
  echo spaced > "$A/my skill/SKILL.md"
  echo other > "$A/other/SKILL.md"
  echo withlinks > "$A/withlinks/SKILL.md"
  ln -s /etc/passwd "$A/withlinks/leak"
  ln -s .. "$A/withlinks/loop"
  ln -s ../../.agents/skills/good "$C/skills/good"               # followed
  ln -s "../../.agents/skills/my skill" "$C/skills/my skill"     # followed, spaces
  ln -s ../../.agents/skills/withlinks "$C/skills/withlinks"     # followed, nested links dropped
  ln -s ../../.agents/skills/other "$C/skills/renamed"           # name mismatch: dropped
  ln -s /tmp "$C/skills/escape"                                  # elsewhere: dropped
  ln -s ../../.agents/skills/missing "$C/skills/dangling"        # dangling: dropped
  ln -s ../.credentials.json "$C/skills/creds"                   # into ~/.claude: dropped
  echo SECRET-CREDS > "$C/.credentials.json"
  echo 'TOKEN=SECRET-ENV' > "$C/skills/real/.env"
  echo '{"k":"SECRET-AUTH"}' > "$C/agents/auth.json"
  echo agent > "$C/agents/a.md"
  echo hook > "$C/hooks/big/h.sh"
  printf '%s\n' '{"model":"opus","keep":true,"env":{"TOKEN":"SECRET-SETTINGS"},"hooks":{"x":1},"statusLine":{"command":"x"},"apiKeyHelper":"/bin/k"}' > "$C/settings.json"
}

# Build a bundle with the current $HOME and env; copy it to $1 (or remove $1
# when no bundle was produced). stderr goes to $2.
build_bundle_to() {
  rm -f "$1"
  mkdir -p "$T/proj"
  (
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_MOUNT="$T/proj" CLAUDE_VM_CLIP=0
    . "$ROOT/vm-claude"
    build_config_bundle
    if [ -n "$CONFIG_BUNDLE" ]; then cp "$CONFIG_BUNDLE" "$1"; fi
  ) 2>"$2"
}

unpack() { rm -rf "$2" && mkdir -p "$2" && tar -xzf "$1" -C "$2"; }

test_config_bundle_contents() {
  setup_config_fixture
  build_bundle_to "$T/b1.tgz" "$T/b1.err"
  check "config: a bundle is produced" [ -f "$T/b1.tgz" ]
  unpack "$T/b1.tgz" "$T/b1"
  local x="$T/b1/claude"

  check "config: skills/<n> -> ~/.agents/skills/<n> becomes a real dir" \
    sh -c "[ -f '$x/skills/good/SKILL.md' ] && [ ! -L '$x/skills/good' ]"
  check "config: ...including names with spaces" [ -f "$x/skills/my skill/SKILL.md" ]
  check "config: regular skills are copied" [ -f "$x/skills/real/SKILL.md" ]
  check "config: a followed package keeps its files" [ -f "$x/skills/withlinks/SKILL.md" ]
  check "config: links nested inside a package are dropped" \
    sh -c "[ ! -e '$x/skills/withlinks/leak' ] && [ ! -e '$x/skills/withlinks/loop' ]"
  check "config: a link to a differently-named package is dropped" [ ! -e "$x/skills/renamed" ]
  check "config: links elsewhere, dangling, or into ~/.claude are dropped" \
    sh -c "[ ! -e '$x/skills/escape' ] && [ ! -e '$x/skills/dangling' ] && [ ! -e '$x/skills/creds' ]"
  check "config: no symlink survives anywhere" [ -z "$(find "$T/b1" -type l)" ]
  check "config: credential-looking files are dropped" \
    sh -c "[ ! -e '$x/skills/real/.env' ] && [ ! -e '$x/agents/auth.json' ] && [ -f '$x/agents/a.md' ]"
  check "config: hooks/ is not shipped by default" [ ! -e "$x/hooks" ]
  check "config: no secret value from the fixture is anywhere in the bundle" \
    sh -c "! grep -rq SECRET '$T/b1'"
  check "config: settings.json keeps ordinary keys" grep -q '"model"' "$x/settings.json"
  check "config: settings.json loses env/hooks/statusLine/apiKeyHelper" \
    sh -c "! grep -qE '\"(env|hooks|statusLine|apiKeyHelper)\"' '$x/settings.json'"
  check "config: manifest file count matches" \
    [ "$(sed -n 's/^files //p' "$T/b1/MANIFEST")" = "$(find "$x" -type f | wc -l | tr -d ' ')" ]
  check "config: manifest lists hooks-free items" sh -c "! grep -q '^item hooks$' '$T/b1/MANIFEST' && grep -q '^item skills$' '$T/b1/MANIFEST'"
  check "config: warns about each dropped link" \
    sh -c "grep -q 'skills/escape' '$T/b1.err' && grep -q 'skills/renamed' '$T/b1.err' && grep -q 'withlinks/leak' '$T/b1.err'"
}

test_config_settings_strip_and_fail_closed() {
  setup_config_fixture
  CLAUDE_VM_SETTINGS_STRIP="model" build_bundle_to "$T/s1.tgz" "$T/s1.err"
  unpack "$T/s1.tgz" "$T/s1"
  check "settings: CLAUDE_VM_SETTINGS_STRIP drops extra keys" sh -c "! grep -q '\"model\"' '$T/s1/claude/settings.json'"

  CLAUDE_VM_SETTINGS_STRIP="" build_bundle_to "$T/s2.tgz" "$T/s2.err"
  unpack "$T/s2.tgz" "$T/s2"
  check "settings: an empty CLAUDE_VM_SETTINGS_STRIP still drops env" sh -c "! grep -q SECRET '$T/s2/claude/settings.json'"

  printf '{"env": {"TOKEN": "SECRET-BROKEN"},\n' > "$HOME/.claude/settings.json"
  build_bundle_to "$T/s3.tgz" "$T/s3.err"
  unpack "$T/s3.tgz" "$T/s3"
  check "settings: invalid JSON is not copied at all" [ ! -e "$T/s3/claude/settings.json" ]
  check "settings: ...and says so" grep -q 'could not sanitize' "$T/s3.err"

  printf '[{"env":"SECRET-ARRAY"}]\n' > "$HOME/.claude/settings.json"
  build_bundle_to "$T/s4.tgz" "$T/s4.err"
  unpack "$T/s4.tgz" "$T/s4"
  check "settings: a non-object JSON is not copied" [ ! -e "$T/s4/claude/settings.json" ]
}

test_config_size_cap() {
  setup_config_fixture
  head -c 4096 /dev/zero | tr '\0' 'x' > "$HOME/.claude/CLAUDE.md"
  CLAUDE_VM_CONFIG_MAX_KB=2 build_bundle_to "$T/cap.tgz" "$T/cap.err"
  check "cap: over the limit, nothing is produced" [ ! -e "$T/cap.tgz" ]
  check "cap: ...and it says so" grep -q 'limit 2KB' "$T/cap.err"
}

# Run the guest-side activation locally against a fake guest $HOME.
activate() {  # $1 = bundle
  local act
  act="$(VM_CLAUDE_SOURCED=1 CLAUDE_VM_MOUNT="$T/proj" CLAUDE_VM_CLIP=0 bash -c ". '$ROOT/vm-claude'; printf '%s' \"\$GUEST_CONFIG_ACTIVATE_SRC\"")"
  mkdir -p "$T/gstate/inbox"
  cp "$1" "$T/gstate/inbox/c.tgz"
  HOME="$T/guest" VM_CLAUDE_STATE="$T/gstate" cfg="$T/gstate/inbox/c.tgz" sh -c "$act"
}

test_config_guest_activation() {
  setup_config_fixture
  build_bundle_to "$T/g1.tgz" "$T/g1.err"
  local G="$T/guest/.claude"
  rm -rf "$T/guest" "$T/gstate" && mkdir -p "$G/hooks" "$G/skills/stale" "$G/projects/p"
  echo old > "$G/hooks/old.sh"
  echo stale > "$G/skills/stale/SKILL.md"
  echo guest-login > "$G/.credentials.json"
  echo transcript > "$G/projects/p/t.jsonl"

  activate "$T/g1.tgz" 2>"$T/g1-act.err"
  check "activate: new config is in place" sh -c "[ -f '$G/skills/good/SKILL.md' ] && [ -f '$G/CLAUDE.md' ]"
  check "activate: legacy hooks/ from the old tar is removed" [ ! -e "$G/hooks" ]
  check "activate: stale skills from a previous copy are removed" [ ! -e "$G/skills/stale" ]
  check "activate: the guest's own login and transcripts are untouched" \
    sh -c "[ -f '$G/.credentials.json' ] && [ -f '$G/projects/p/t.jsonl' ]"
  check "activate: the bundle file is cleaned up" [ ! -e "$T/gstate/inbox/c.tgz" ]

  rm -rf "$HOME/.claude/agents"
  build_bundle_to "$T/g2.tgz" "$T/g2.err"
  activate "$T/g2.tgz" 2>/dev/null
  check "activate: an item removed on the host disappears from the guest" [ ! -e "$G/agents" ]

  # Tampered: manifest says one more file than the archive holds.
  unpack "$T/g2.tgz" "$T/g3"
  awk '/^files /{ $2 = $2 + 1 } { print }' "$T/g3/MANIFEST" > "$T/g3/M" && mv "$T/g3/M" "$T/g3/MANIFEST"
  rm -f "$T/g3/claude/CLAUDE.md"
  tar -czf "$T/g3.tgz" -C "$T/g3" MANIFEST claude
  activate "$T/g3.tgz" 2>"$T/g3-act.err"
  check "activate: a bundle failing its manifest check changes nothing" [ -f "$G/CLAUDE.md" ]
  check "activate: ...and says so" grep -q 'integrity check' "$T/g3-act.err"

  head -c 100 "$T/g2.tgz" > "$T/g4.tgz"
  activate "$T/g4.tgz" 2>/dev/null || true
  check "activate: a truncated bundle changes nothing" sh -c "[ -f '$G/CLAUDE.md' ] && [ -f '$G/skills/good/SKILL.md' ]"
}

# --- fresh boot, resume and --shell run the same guest setup ------------------
test_entry_paths_share_setup() {
  setup_config_fixture
  mkdir -p "$T/proj" "$T/msb-calls"
  rm -f "$T/msb-calls"/*
  (
    export VM_CLAUDE_SOURCED=1 CLAUDE_VM_MOUNT="$T/proj" CLAUDE_VM_CLIP=0
    . "$ROOT/vm-claude"
    n=0
    msb() {  # record the script that follows -lc, and the args after it
      local prev="" a out
      n=$((n + 1)); out="$T/msb-calls/$n"
      printf '%s %s\n' "$1" "$2" >> "$T/msb-calls/log"
      for a in "$@"; do
        if [ "$prev" = "-lc" ]; then printf '%s' "$a" > "$out.script"; : > "$out.args"
        elif [ -e "$out.args" ]; then printf '%s\n' "$a" >> "$out.args"; fi
        prev="$a"
      done
      cat > /dev/null 2>&1 || true
    }
    build_config_bundle
    start_fresh claude --dangerously-skip-permissions
    resume sh -l
  ) </dev/null 2>/dev/null

  local fresh resume_call
  fresh="$(ls "$T/msb-calls"/*.script | head -1)"
  resume_call="$(ls "$T/msb-calls"/*.script | tail -1)"
  check "entry: fresh boot and resume send an identical setup script" cmp -s "$fresh" "$resume_call"
  check "entry: the generated setup script parses as POSIX sh" sh -n "$fresh"
  check "entry: fresh boot passes the bundle path and claude" \
    sh -c "sed -n '4p' '${fresh%.script}.args' | grep -q '/var/lib/vm-claude/inbox/config-' && sed -n '5p' '${fresh%.script}.args' | grep -qx claude"
  check "entry: msb calls are run, then exec --stream (bundle), then exec -t (session)" \
    [ "$(tr '\n' '|' < "$T/msb-calls/log")" = "run -t|exec --stream|exec -t|" ]
  check "entry: resume hands the guest the bundle path it streamed" \
    sh -c "[ -n \"\$(sed -n 4p '$T/msb-calls/3.args')\" ] && [ \"\$(sed -n 4p '$T/msb-calls/3.args')\" = \"\$(sed -n 4p '$T/msb-calls/1.args')\" ]"
  check "entry: resume execs the requested command after setup" [ "$(sed -n '5p;6p' "$T/msb-calls/3.args" | tr '\n' ' ')" = "sh -l " ]
}

test_config_bundle_contents
test_config_settings_strip_and_fail_closed
test_config_size_cap
test_config_guest_activation
test_entry_paths_share_setup
test_sign_on_exit_ignores_poisoned_repo
test_sign_on_exit_clean_session_no_warning
test_worktree_create_ignores_poisoned_hooks
test_worktree_create_refuses_local_filters
test_worktree_refuses_symlinked_holder

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
