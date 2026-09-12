# vm-claude

`vm-claude` runs Claude Code inside a [microsandbox](https://docs.microsandbox.dev) microVM instead of directly on your machine.

The point is isolation: the guest sees **only the current project**, mounted read-write at `/workspace`. Everything else on the host — your home directory, SSH keys, other repos, system files — is simply not there, so a stray `rm -rf` or an over-eager tool call can't reach it. The one door back to the host is the project itself, `.git` included — see [The repo is guest-writable](#the-repo-is-guest-writable).

Because the VM is already the sandbox, `claude` is started with `--dangerously-skip-permissions` by default — no permission prompts inside the box. See [Permissions](#permissions).

Auth, config, and session state live in the VM's own root disk and are keyed per project, so signing in and resuming happen once per project rather than once per run. Your own Claude configuration — global `CLAUDE.md`, settings, custom agents and commands — is carried in from the host on every run; see [Claude config](#claude-config).

## Requirements

- Linux or macOS
- `curl` and `bash`
- The `msb` (microsandbox) CLI — **installed automatically on first run** if it isn't already on your `PATH`

## Install

Drop the script somewhere on your `PATH` and make it executable:

```bash
install -m 755 vm-claude ~/.local/bin/vm-claude
```

Or, from a checkout, with [`just`](https://github.com/casey/just):

```bash
just install              # copy this checkout's vm-claude to ~/.local/bin
just tag 1.2.0 ["notes"]  # lint + test, tag v1.2.0, push it, publish the GitHub Release, then install it
```

`just tag` only runs from a clean `main` that matches `origin/main`, and stops before tagging if lint or tests fail.

## Usage

```bash
vm-claude                 # run claude in a VM for the current project
vm-claude --shell         # drop into a shell in the VM instead of running claude
vm-claude --show-config   # list the ~/.claude files a run would copy in (starts nothing)
vm-claude --stop          # stop this project's VM
vm-claude --rm            # stop + delete the VM (wipes its auth/session state)
vm-claude --sign-on-exit  # sign the commits the VM made, on the host, on exit
vm-claude --no-clip       # disable the clipboard bridge (on by default)
vm-claude --worktree NAME # run in a git worktree (created if missing), same VM
vm-claude --cpus 4 --memory 8G --disk 16G
                          # sizes for this run (a new VM boots with them; an
                          # existing one needs --resize)
vm-claude --max-cpus 8 --max-memory 32G
                          # headroom a later --resize can grow into
vm-claude --resize        # push the sizes above onto the existing VM
vm-claude -- <args...>    # pass args straight through to `claude`
```

Examples:

```bash
cd ~/code/my-project
vm-claude                             # first run: boots a VM, installs claude, starts it
vm-claude                             # later runs: resumes the same VM instantly
vm-claude -- --resume                 # forward flags to claude itself
vm-claude -- -p "explain this repo"   # one-shot print mode

cd ~/code/my-project/src/deep/dir
vm-claude                             # same VM as the repo root, but starts in this dir
```

## Permissions

By default `vm-claude` invokes `claude --dangerously-skip-permissions` (with `IS_SANDBOX=1` set inside the guest, which is what allows the flag to be used as root there). The isolation you'd normally get from approving each tool call is already provided by the VM boundary: only the project directory is visible, and everything else in the guest is throwaway.

To get the normal permission prompts back:

```bash
CLAUDE_VM_SKIP_PERMISSIONS=0 vm-claude
```

Note that the flag applies to the *filesystem* only. Claude still has network access from inside the VM (see the caveats below), so treat a `vm-claude` session as unattended-but-online.

## Signing commits

No signing key and no git credentials are ever copied into the guest, so commits made in the VM are unsigned and pushing from inside doesn't work. That's deliberate — but it means a VM session leaves a run of unsigned commits behind.

`--sign-on-exit` closes that gap on the host side:

```bash
vm-claude --sign-on-exit
```

It records `HEAD` before starting the VM and, when the VM exits, signs whatever was committed in the meantime with your host key. When it arms it says so — `sign-on-exit: armed at <sha>` — so an active hook is distinguishable from a flag you forgot to pass. `--shell` sessions are covered too, and so are the messy exits: it signs on a clean `/q`, on Ctrl-C, and when you just close the terminal (`SIGINT`/`SIGTERM`/`SIGHUP`), not only on a graceful shutdown. This works because `/workspace` **is** your host repo — the git root is what's mounted, so commits made in the guest are already real objects in the host's `.git`; only the signature is missing. The hook re-creates them out here, where the key lives.

It does that **without letting the repo run anything on your host**. The VM can write the repo's `.git/config` and `.git/hooks`, and git honours both, so a plain `git rebase -S` on the host would run whatever `gpg.ssh.program`, `core.fsmonitor` or hook the session planted — as you, with your keys. Instead the hook:

- reads your signing settings (`user.*`, `gpg.format`, `gpg.*program`, `user.signingkey`) from your **global** git config before the VM starts, never from the repo;
- re-creates each new commit with `git commit-tree -S` in a throwaway git directory that shares only the repo's object store, so no repo config and no hooks are in play;
- moves the branch with a compare-and-swap `update-ref`, hooks disabled.

Trees, authors, author dates and messages are kept exactly; merges keep their parents; the committer becomes your global identity. Because the trees are identical, the index and working tree aren't touched — uncommitted work stays as it was, no autostash.

It's already the default when your host is set up to sign commits anyway — if `commit.gpgsign` is `true` in your global git config, every `vm-claude` run arms it without the flag. Set `CLAUDE_VM_SIGN_ON_EXIT=1` to force it on regardless (or `=0` / `--no-sign-on-exit` to turn it off for one run). The hook deliberately does nothing and tells you so when it can't act safely: a detached `HEAD`, no new commits, or a history that diverged from where it started (a rebase or reset inside the VM), since rewriting from the old base would discard work. If signing fails, nothing is rewritten and it prints the command to retry by hand — review `.git/config` and `.git/hooks` before running it.

Signing rewrites the commits, so their hashes change. Run it before pushing, not after.

Two things it deliberately cannot do. It only signs commits made **during that run** — anything already unsigned when the VM started sits below the recorded base and stays untouched, so catch those up by hand with `git rebase -f -S <last good commit>`. And the hook lives in the running `vm-claude` process: editing the script, or deciding to enable the flag, does nothing for a session that is already up. A VM started without it will exit without it.

## The repo is guest-writable

The project directory is mounted read-write, `.git` and all, and inside the VM Claude runs as root with permission prompts off. Treat everything in the repo as something the session may have changed — including the parts **host git executes**:

- `.git/config` entries such as `core.fsmonitor`, `core.hooksPath`, `gpg.program`, `diff.*.textconv`, `filter.*.smudge`, aliases;
- hooks in `.git/hooks/` (or wherever `core.hooksPath` points);
- tracked scripts your tooling runs (`package.json` scripts, `Makefile`, `.envrc`, husky hooks).

`vm-claude` keeps its own git calls from running any of that: every host git command it issues on the repo disables hooks and fsmonitor, signing runs outside the repo's config (above), and `--worktree` refuses to create a checkout if the repo defines filter drivers or config includes, or if its target path is a symlink.

What it can't protect is **your** next git command. So on exit it compares the repo's executable config and hooks against what was there before the session and warns if anything was added or changed:

```text
warning: this session added or changed executable git config in /path/to/repo/.git:
  core.fsmonitor
  hook /path/to/repo/.git/hooks/post-checkout
```

If you see that and didn't do it yourself, inspect and remove it before running git in that repo — `git config --file .git/config --list` reads the file without executing anything. Setting these in your global config won't help: a repo's own config overrides global. For tracked tooling, `git diff` the session's changes before you run them.

## Git worktrees

`--worktree NAME` runs Claude in a [git worktree](https://git-scm.com/docs/git-worktree)
of the project instead of at the repo root, so you can drive several branches in
parallel — **without booting a second VM**:

```bash
vm-claude --worktree feat-x     # work on branch feat-x in its own dir
vm-claude --worktree bugfix     # another one, same VM
vm-claude                       # still the repo root, same VM
```

The worktree lives **under the repo root** at `.vm-worktrees/NAME`, which is why
it can share the VM: that path is already inside the `/workspace` mount, so an
already-running VM sees it live with no `--rm` and no reboot. (Mounts are fixed
at boot; a worktree placed *outside* the root couldn't be reached without a fresh
VM.) `.vm-worktrees/` is added to `.git/info/exclude` on first use, so the main
repo never reports the worktrees as untracked. Change the location with
`CLAUDE_VM_WORKTREE_DIR`.

If the worktree doesn't exist yet it's **created for you**: a new branch `NAME`
off the current `HEAD`, or a checkout of branch `NAME` if it already exists. It's
created with `git worktree add --relative-paths` (git ≥ 2.48) so the worktree's
`.git` pointer files use relative paths and resolve correctly both on the host
and under `/workspace` in the guest — the guest's older git reads relative links
fine even though it can't write them. On an older host git the links are
relativized by hand as a fallback.

**Gitignored files are copied in on creation.** A fresh `git worktree add` checks
out only *tracked* files, so a new worktree has none of your `.env`, secrets, or
other ignored/untracked files. On the first creation `vm-claude` copies every
untracked and gitignored file from the main working tree into the new worktree
(via `git ls-files --others [--ignored]` piped through `tar`). This happens
**only when the worktree is created** — later runs leave the worktree's own
copies alone, so edits you make to its `.env` inside the VM stick.

**Creation refuses when the repo could run code on the host.** The checkout
happens on the host, in a repo the VM can write. Hooks and fsmonitor are
disabled for it, but filter drivers (`filter.*.smudge`) can't be switched off
by name, so if the repo's own config defines any, or pulls in other config via
`include.path`/`includeIf`, `vm-claude` stops and lists them. It also refuses
when `.vm-worktrees` or the worktree path is a symlink. See
[The repo is guest-writable](#the-repo-is-guest-writable).

`--sign-on-exit` follows the worktree: it records and re-signs `HEAD` on the
worktree's branch, not the repo root's. Removing a worktree is manual — the tool
never deletes one; use `git worktree remove .vm-worktrees/NAME` (and `git branch
-d NAME`) when you're done.

## Pasting images (clipboard bridge)

Ctrl-V image paste doesn't work in a plain `vm-claude` session, and it can't:
Claude Code reads a pasted image by shelling out to `xclip`/`wl-paste` **inside
the guest**, but the guest has no clipboard and no line to your Mac's pasteboard.
The image sits in the host clipboard while the program trying to read it is in a
box that can't see it. (Text paste works because text rides through the terminal
as an ordinary paste; images don't.)

The clipboard bridge fixes it, and it's **on by default** — you paste with
Ctrl-V as normal, and each time Claude reaches for the clipboard a **dialog
appears on your Mac** asking you to approve that one paste. Click Allow and the
image drops in. Nothing is read without your click. Turn it off with:

```bash
vm-claude --no-clip       # or CLAUDE_VM_CLIP=0 vm-claude
```

**How it works.** A shared directory is mounted into the guest, and a shim named
`xclip` is installed there. When you paste, the shim drops a content-free trigger
in the shared dir; a small watcher process on your Mac sees it, shows the
Allow/Deny dialog, and — only on Allow — serves the current pasteboard back
through the dir for Claude to read. The request originates *in the VM you're
pasting into*, so it always targets the right session no matter how your windows
or terminal panes are split (a host-side hotkey can't tell panes apart, which is
why this is dialog-per-paste rather than a keybinding).

**Why the dialog is the whole point.** Because the guest triggers the read, a
compromised or prompt-injected guest could ask for your clipboard whenever it
likes — not just when you meant to paste — and it has network access to send it
onward. The per-paste approval is what stops a silent read: the guest can make
the dialog *appear*, but can't get anything without a human click, and a guest
spamming requests just produces visible dialogs you deny. The unavoidable
residual: while a `--clip` session is running, treat your clipboard as reachable
by the box on approval — don't copy secrets you wouldn't hand it, and leave the
feature off when you don't need it.

The bridge is written to keep the shared directory from becoming an escape hatch:
the guest's trigger files are acted on by *existence only* — their contents are
never read — and everything served back is staged in a host-only directory and
renamed onto the same filesystem into the shared mount, so a symlink the guest
plants there can't redirect a host write. The dialog text is composed on the
host; no guest bytes ever reach it.

Two practical notes:

- **macOS host only.** On a non-macOS host the bridge is silently skipped (pass `--clip` explicitly there and it says why).
- **Images need [`pngpaste`](https://github.com/jcsalterego/pngpaste)**, which is **installed for you via Homebrew** on first use if it's missing — the same way `msb` is. If it can't be installed (no Homebrew, or the install fails), image paste degrades off with a warning and text paste still works.
- **The shared directory is an extra mount**, and mounts are fixed when the VM boots. A VM created before the bridge existed won't have the mount, so on those the bridge needs `vm-claude --rm` and a fresh start; the session warns when it resumes a VM whose bridge isn't wired up.
- **Host state and lifecycle.** The watcher and its shared/staging dirs live under `~/.cache/vm-claude/clip/<vm-name>/`. The watcher runs only while a session is up: it's reaped on exit, self-terminates if its `vm-claude` dies without reaping it (e.g. a `kill -9`), and `--stop`/`--rm` also reap a stray one. `--rm` additionally deletes that VM's cache dir; `--stop` leaves it (it's recreated on the next run). Nothing polls or reads your clipboard when no session is running.

## Timezone

The base image runs UTC, which would stamp every commit made in the VM with a `+0000` offset while your host commits carry the real local one. `vm-claude` installs `tzdata` in the guest and pins its clock to the host's zone — read from `$TZ`, `/etc/timezone`, or the `/etc/localtime` symlink, whichever answers first. Override with `CLAUDE_VM_TZ=Europe/Lisbon`; an unrecognizable value is ignored rather than passed through.

## How it works

1. The mount directory (default `$PWD`) is resolved to an absolute path. If it's inside a git repo, the **repo root** is mounted instead, so `.git` is visible in the guest, and the sub-path is remembered so you land in the equivalent directory under `/workspace`.
2. That path is hashed, producing a stable VM name like `vm-claude-my-project-1234567890`. Each project therefore gets its own persistent VM.
3. **First run** — `msb run` boots the base image with the project mounted at `/workspace` and your `~/.claude` bundle copied in (see below). Inside the guest it installs `ca-certificates`, `git`, and `tzdata`, pins the timezone, copies over a safe subset of your host git config (see below), runs `npm install -g @anthropic-ai/claude-code@<version>`, swaps in the `~/.claude` bundle, and execs `claude`.
4. **Later runs** — the VM already exists, so the bundle is streamed in over `msb exec --stream` and the session is resumed with `msb exec`. `claude` is re-installed at `CLAUDE_VM_VERSION` on the way in so each session picks up the latest release (skipped gracefully if the install fails — the version already in the VM is used); you stay logged in, and the `~/.claude` config is refreshed from the host too.

`--shell` goes through exactly the same setup as a normal run (fresh boot or resume) and just execs a shell at the end instead of `claude`.
5. `--stop` shuts the VM down but keeps its disk. `--rm` deletes it, which also destroys the stored credentials and session history for that project.

The first run in a project boots the base image and installs the OS packages, so expect a minute or two; later runs skip all that and only refresh `claude` itself, so they start in a few seconds.

## Git config

So that commits made in the VM aren't authored by `root@<vm>`, the first boot copies an explicit allowlist of `git config --global` values from the host: `user.name`, `user.email`, `init.defaultBranch`, `pull.rebase`, `push.default`, `push.autoSetupRemote`, `rebase.autostash`, `fetch.prune`, `merge.conflictstyle`, `diff.colorMoved`, `color.ui`, and all your `alias.*` entries.

Anything that could carry a secret — `credential.*`, `*.token`, `user.signingkey`, `gpg.*`, `http.*`, `url.*.insteadOf`, `sendemail.*` — is deliberately **not** copied. There are no host credentials in the guest, so pushing from inside the VM won't work out of the box, and commits come out unsigned; see [Signing commits](#signing-commits).

## Claude config

The guest has its own `~/.claude` — that's where its auth and session state live — so without help it would start with none of your actual configuration: no global `CLAUDE.md`, no settings, no custom agents or commands. On every run `vm-claude` copies an allowlist of your host config in:

`CLAUDE.md`, `settings.json`, `keybindings.json`, `agents/`, `commands/`, `skills/`, `output-styles/`

(`hooks/` used to be on the list. It isn't any more: the `hooks` key in `settings.json` never crosses, so the scripts were dead weight — often megabytes. A VM that still has an old copy loses it on its next run.)

Everything else in `~/.claude` stays on the host. In particular `.credentials.json`, `history.jsonl`, `projects/` (the transcripts of every project you've ever run Claude in), `sessions/`, `shell-snapshots/` and the plugin repos are never sent — you still sign in separately inside each VM.

It's **not** a mount. Mounting `~/.claude` would have been simpler, but it would put your credentials and every other project's transcripts inside the box for the VM's whole lifetime, which is the thing this tool exists to prevent. Instead the allowlist is staged in a private temp dir on the host, cleaned there, packed into one tarball with a manifest, copied into the guest, checked against that manifest, and only then swapped in. A bundle that fails the check changes nothing.

Cleaning happens **on the host, before anything is copied**:

- **Symlinks.** Exactly one shape is followed: `skills/<name>` pointing at `~/.agents/skills/<name>`, the layout skill installers create. It's copied in as a real directory. Every other link is dropped with a message: a dangling one, one pointing anywhere else, a top-level item that is itself a link (e.g. `CLAUDE.md` into a dotfiles repo), or a link nested inside a copied skill. Copying links as-is used to leave them dangling in the guest; following them blindly could pull any host file in.
- **Credential-looking files** are dropped wherever they appear: `.credentials.json`, `credentials.json`, `auth.json`, `.netrc`, `.npmrc`, `.pypirc`, `history.jsonl`, `id_rsa`/`id_ed25519`/…, `*.pem`, `*.key`, `*.p12`, `.env`, `.env.*`.
- **`settings.json`** loses `env`, `hooks`, `statusLine`, `apiKeyHelper`, `awsAuthRefresh`, `awsCredentialExport` and `otelHeadersHelper` — always. `env` is where tokens usually live; the rest run host-side commands that don't exist in the VM. Add more keys with `CLAUDE_VM_SETTINGS_STRIP`. This needs `jq`, `node` or `python3` on the host; if none is there, or the file isn't a JSON object, `settings.json` is **not copied at all** rather than copied unsanitized. Your host `settings.json` is never modified.

It runs on resumes too, not just the first boot, so edits to your host config show up on the next run. The copied entries are replaced wholesale each time, and an entry that disappears from the host (or from the allowlist) is removed from the guest too — so config changes made *inside* the VM to those entries don't stick. Everything else in the guest's `~/.claude` — including its login and transcripts — is left alone.

See exactly what would go in, without starting anything:

```bash
vm-claude --show-config
```

Every run also prints a one-line summary (`config: copying 54 file(s), 235KB, ...`).

Tune it with:

```bash
CLAUDE_VM_CONFIG=0 vm-claude                              # don't copy anything
CLAUDE_VM_CONFIG_ITEMS="CLAUDE.md agents" vm-claude       # copy just these
CLAUDE_VM_CONFIG_DIR=~/dotfiles/claude vm-claude          # copy from elsewhere
CLAUDE_VM_SETTINGS_STRIP="permissions" vm-claude          # also drop these settings keys
```

There's a **size ceiling**, 2 MB uncompressed by default. It isn't a transport limit (the bundle travels as a file); it's a guard against shipping far more of your machine than you meant to. Over the limit, `vm-claude` says so and copies nothing; check `--show-config`, then trim `CLAUDE_VM_CONFIG_ITEMS` or raise `CLAUDE_VM_CONFIG_MAX_KB`.

## Configuration

All configuration is via environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_VM_VERSION` | `latest` | npm version of `@anthropic-ai/claude-code`, (re)installed on every start and resume; pin to a version (e.g. `2.1.235`) to hold it |
| `CLAUDE_VM_IMAGE` | `public.ecr.aws/docker/library/node:24-bookworm-slim` | Base OCI image |
| `CLAUDE_VM_CPUS` | `2` | vCPUs |
| `CLAUDE_VM_MEMORY` | `4G` | RAM |
| `CLAUDE_VM_DISK` | `4G` | Root disk size |
| `CLAUDE_VM_MAX_CPUS` | same as `CLAUDE_VM_CPUS` | Ceiling a live `--resize` can raise vCPUs to; fixed when the VM boots |
| `CLAUDE_VM_MAX_MEMORY` | same as `CLAUDE_VM_MEMORY` | Ceiling a live `--resize` can raise RAM to; fixed when the VM boots |
| `CLAUDE_VM_MOUNT` | git repo root of `$PWD`, else `$PWD` | Host directory mounted as `/workspace` |
| `CLAUDE_VM_SKIP_PERMISSIONS` | `1` | `1` passes `--dangerously-skip-permissions`; `0` keeps the prompts |
| `CLAUDE_VM_SIGN_ON_EXIT` | host `commit.gpgsign` | `1`/`0` forces `--sign-on-exit` on/off; unset, it defaults on when the host has `commit.gpgsign=true` |
| `CLAUDE_VM_TZ` | the host's zone | Timezone for the guest, e.g. `Europe/Lisbon` |
| `CLAUDE_VM_CLIP` | `1` | `1` (default) bridges the macOS clipboard into the guest so Ctrl-V image paste works, approving each paste via a host dialog; `0` (or `--no-clip`) turns it off. macOS host only; `pngpaste` is auto-installed via Homebrew |
| `CLAUDE_VM_CONFIG` | `1` | `1` copies the `~/.claude` allowlist into the guest; `0` skips it |
| `CLAUDE_VM_CONFIG_DIR` | `~/.claude` | Host directory to copy that config from |
| `CLAUDE_VM_CONFIG_ITEMS` | see [Claude config](#claude-config) | Space-separated allowlist of entries to copy |
| `CLAUDE_VM_CONFIG_MAX_KB` | `2048` | Size ceiling for the copied config, uncompressed, in KB |
| `CLAUDE_VM_SETTINGS_STRIP` | *(none)* | Extra space-separated `settings.json` keys to drop; `env`, `hooks`, `statusLine` and the credential-helper keys are always dropped |
| `CLAUDE_VM_WORKTREE_DIR` | `.vm-worktrees` | Subdir under the repo root that holds `--worktree` checkouts |

```bash
CLAUDE_VM_CPUS=4 CLAUDE_VM_MEMORY=8G vm-claude
CLAUDE_VM_MOUNT=~/code/other-project vm-claude
```

The default image is the AWS ECR public mirror of Docker's official Node image — anonymous pulls, no Docker Hub rate limits or `401`s. Point `CLAUDE_VM_IMAGE` at a Docker Hub tag if you'd rather use that.

Setting `CLAUDE_VM_MOUNT` explicitly also disables the git-root detection: the directory you name is mounted as-is. Since the VM name is derived from that path, a different mount means a different VM with its own state.

## Resizing a VM

`CLAUDE_VM_CPUS`, `CLAUDE_VM_MEMORY` and `CLAUDE_VM_DISK` (or `--cpus`, `--memory`, `--disk`) apply when a VM is **created**. On an existing VM they're ignored unless you add `--resize`:

```bash
vm-claude --resize --cpus 4 --memory 8G            # live, the VM keeps running
vm-claude --resize --disk 32G                      # reboots, to grow the disk
vm-claude --resize --max-cpus 8 --max-memory 32G   # reboots, to raise the ceiling
```

Only CPU and RAM change live. Anything else — a bigger disk, a higher ceiling — needs a reboot, which `--resize` handles for you. That reboot is not a `--rm`: the VM's disk, auth and session history all survive it.

| Change | Boundary |
| --- | --- |
| CPU / RAM, within the ceiling | live |
| CPU / RAM ceiling (`--max-cpus`, `--max-memory`) | reboot |
| Root disk (grow only) | reboot |

One trap worth knowing up front: `--resize` includes the disk whenever a disk size was asked for, **and a `CLAUDE_VM_DISK` exported in your shell profile counts**. Export it and every `--resize` reboots, even a plain CPU bump. Pass `--disk` per run instead if that bothers you.

Re-running the same `--resize --disk 32G` is fine, though: `msb modify` is all-or-nothing and would refuse the whole thing because the disk is already 32G, so vm-claude notices that refusal, says so, and retries without the disk. The CPU/RAM part still lands.

### Ceilings

CPU and RAM grow live only up to a ceiling fixed when the VM booted, and that ceiling defaults to the VM's starting size — so a VM booted without `--max-*` can be resized down but not up. Ask for headroom the first time:

```bash
vm-claude --cpus 2 --memory 4G --max-cpus 8 --max-memory 32G
```

It's a limit, not a reservation: it costs nothing until claimed, so set it generously. Raising it later works too, at the price of one reboot. `msb ps` shows the current allocation as `effective / max`.

The root disk only ever grows. Shrinking it isn't possible — the only way down is `--rm` and a fresh VM.

A refused resize — no headroom, a CPU/RAM shrink below what's allowed, or an `msb` too old to have `modify` — is reported, and the session continues at the VM's current size. It never blocks the run. `--resize` on a project with no VM yet does nothing, since a fresh boot already uses whatever sizes you passed.

### Checking what a VM actually got

From inside the guest:

```bash
nproc                                                        # vCPUs
awk '/MemTotal/{printf "%.2f GiB\n", $2/1048576}' /proc/meminfo
df -h /                                                      # root disk
```

The base image ships without `procps`, so there's no `free` or `top` unless you `apt-get install -y procps`.

### VMs created before this existed

They keep working, and nothing about a plain `vm-claude` run changed. What they don't have is headroom: they booted with the ceiling defaulted to their starting size, so `--resize` can only shrink their CPU/RAM until you give them room. That doesn't need a `--rm` — one reboot is enough, and the VM's disk, auth and session history survive it:

```bash
vm-claude --resize --max-cpus 8 --max-memory 32G   # one-time, per project VM
vm-claude --resize --cpus 6                        # from then on, live
```

Growing an old VM's disk works right away, with no prior setup — the root disk was never ceiling-bound, only reboot-bound:

```bash
vm-claude --resize --disk 32G
```

Both need an `msb` new enough to have `modify` (`msb self update` if not). vm-claude only sends `--max-cpus`/`--max-memory` when you actually ask for a ceiling, so an older `msb` keeps working for everything else.

## Tests

```bash
test/run.sh
```

Host-only: no VM and no `msb` needed. It sources the script into throwaway repos and a throwaway `$HOME` and checks the security-relevant host logic. That covers signing against a repo whose `.git` has been poisoned, `--worktree` refusals, the config bundle's link/credential/settings handling, the guest-side swap-in, and that a fresh boot, a resume and `--shell` all run the same setup.

## Notes and caveats

- **Sign-in is per project.** Because state lives in the per-project VM disk, the first run in each new project asks you to authenticate again. Credentials are never copied from the host — only the config allowlist is. `--rm` resets that.
- **The VM has network access**, which is what makes `npm install` and the Claude API work. Isolation here is about the filesystem, not the network.
- **Only `/workspace` persists on the host.** Anything Claude writes elsewhere in the guest lives in the VM disk and disappears with `--rm`.
- **`claude` is (re)installed on every start and resume**, so each session picks up the newest release (`CLAUDE_VM_VERSION` defaults to `latest`). On a resume the update is best-effort — if the install fails (e.g. no network), the version already in the VM is used and the session still starts. Pin `CLAUDE_VM_VERSION` to a specific version to hold `claude` steady across sessions.
- Upstream docs: <https://docs.microsandbox.dev/examples/agents/claude-code>
