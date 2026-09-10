# vm-claude

`vm-claude` runs Claude Code inside a [microsandbox](https://docs.microsandbox.dev) microVM instead of directly on your machine.

The point is isolation: the guest sees **only the current project**, mounted read-write at `/workspace`. Everything else on the host — your home directory, SSH keys, other repos, system files — is simply not there, so a stray `rm -rf` or an over-eager tool call can't reach it.

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

## Usage

```bash
vm-claude                 # run claude in a VM for the current project
vm-claude --shell         # drop into a shell in the VM instead of running claude
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

It records `HEAD` before starting the VM and, when the VM exits, signs whatever was committed in the meantime with your host key. When it arms it says so — `sign-on-exit: armed at <sha>` — so an active hook is distinguishable from a flag you forgot to pass. `--shell` sessions are covered too, and so are the messy exits: it signs on a clean `/q`, on Ctrl-C, and when you just close the terminal (`SIGINT`/`SIGTERM`/`SIGHUP`), not only on a graceful shutdown. This works because `/workspace` **is** your host repo — the git root is what's mounted, so commits made in the guest are already real objects in the host's `.git`; only the signature is missing. The hook re-creates them out here, where the key lives:

```bash
git rebase --force-rebase --gpg-sign --autostash <HEAD before the VM ran>
```

`--force-rebase` is the load-bearing flag. A plain `git rebase -S origin/main` onto an ancestor fast-forwards, re-creates no commits, and therefore signs nothing — a quiet no-op that looks like a signing failure.

It's already the default when your host is set up to sign commits anyway — if `commit.gpgsign` is `true` in your global git config, every `vm-claude` run arms it without the flag. Set `CLAUDE_VM_SIGN_ON_EXIT=1` to force it on regardless (or `=0` / `--no-sign-on-exit` to turn it off for one run). The hook deliberately does nothing and tells you so when it can't act safely: a detached `HEAD`, no new commits, or a history that diverged from where it started (a rebase or reset inside the VM), since rewriting from the old base would discard work. If the rebase itself fails it runs `git rebase --abort` and prints the command to retry by hand — it never leaves you mid-rebase.

Signing rewrites the commits, so their hashes change. Run it before pushing, not after.

Two things it deliberately cannot do. It only signs commits made **during that run** — anything already unsigned when the VM started sits below the recorded base and stays untouched, so catch those up by hand with `git rebase -f -S <last good commit>`. And the hook lives in the running `vm-claude` process: editing the script, or deciding to enable the flag, does nothing for a session that is already up. A VM started without it will exit without it.

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
3. **First run** — `msb run` boots the base image with the project mounted at `/workspace`, then inside the guest installs `ca-certificates`, `git`, and `tzdata`, pins the timezone, copies over a safe subset of your host git config (see below), runs `npm install -g @anthropic-ai/claude-code@<version>`, unpacks a safe subset of your `~/.claude` config (see below), and execs `claude`.
4. **Later runs** — the VM already exists, so it's resumed with `msb exec` and `claude` starts right up. `claude` is re-installed at `CLAUDE_VM_VERSION` on the way in so each session picks up the latest release (skipped gracefully if the install fails — the version already in the VM is used); you stay logged in, and the `~/.claude` subset is refreshed from the host too.
5. `--stop` shuts the VM down but keeps its disk. `--rm` deletes it, which also destroys the stored credentials and session history for that project.

The first run in a project boots the base image and installs the OS packages, so expect a minute or two; later runs skip all that and only refresh `claude` itself, so they start in a few seconds.

## Git config

So that commits made in the VM aren't authored by `root@<vm>`, the first boot copies an explicit allowlist of `git config --global` values from the host: `user.name`, `user.email`, `init.defaultBranch`, `pull.rebase`, `push.default`, `push.autoSetupRemote`, `rebase.autostash`, `fetch.prune`, `merge.conflictstyle`, `diff.colorMoved`, `color.ui`, and all your `alias.*` entries.

Anything that could carry a secret — `credential.*`, `*.token`, `user.signingkey`, `gpg.*`, `http.*`, `url.*.insteadOf`, `sendemail.*` — is deliberately **not** copied. There are no host credentials in the guest, so pushing from inside the VM won't work out of the box, and commits come out unsigned; see [Signing commits](#signing-commits).

## Claude config

The guest has its own `~/.claude` — that's where its auth and session state live — so without help it would start with none of your actual configuration: no global `CLAUDE.md`, no settings, no custom agents or commands. On every run `vm-claude` copies an allowlist of your host config in:

`CLAUDE.md`, `settings.json`, `keybindings.json`, `agents/`, `commands/`, `skills/`, `hooks/`, `output-styles/`

Everything else in `~/.claude` stays on the host. In particular `.credentials.json`, `history.jsonl`, `projects/` (the transcripts of every project you've ever run Claude in), `sessions/`, `shell-snapshots/` and the plugin repos are never sent — you still sign in separately inside each VM.

The copy is a small gzipped tar inlined into the command that boots or resumes the VM, **not** a second mount. Mounting `~/.claude` would have been simpler, but it would put your credentials and every other project's transcripts inside the box for the VM's whole lifetime, which is the thing this tool exists to prevent.

It runs on resumes too, not just the first boot, so edits to your host config show up on the next run. The flip side: those specific files are overwritten in the guest each time, so config changes made *inside* the VM don't stick. Everything not on the allowlist — including the VM's login — is left alone.

`settings.json` gets one edit on the way in: a configurable set of top-level keys is deleted from the guest's copy. The default is `hooks statusLine` — the two keys that shell out to host-side executables (hooks and status-line scripts run by absolute path or host-only binary), none of which exist in the VM, so left in place they'd make every session event fire a hook that errors. Everything else — model, effort, plugins, permissions — is kept. Change the list with `CLAUDE_VM_SETTINGS_STRIP` (space-separated keys; `""` keeps everything, `"hooks statusLine env"` also drops `env`). The edit happens on the copy inside the guest; your host `settings.json` is untouched.

Tune it with:

```bash
CLAUDE_VM_CONFIG=0 vm-claude                              # don't copy anything
CLAUDE_VM_CONFIG_ITEMS="CLAUDE.md agents" vm-claude       # copy just these
CLAUDE_VM_CONFIG_DIR=~/dotfiles/claude vm-claude          # copy from elsewhere
```

Two caveats worth knowing:

- **`settings.json` goes across almost as-is.** `hooks` and `statusLine` are stripped in the guest (see above), but the rest is copied verbatim — so if yours has secrets in `env`, drop `settings.json` from `CLAUDE_VM_CONFIG_ITEMS`.
- **There's a size ceiling**, 120 KB of compressed payload by default, because it travels as a single command-line argument and Linux caps those at 128 KB — the default leaves a little headroom under that hard limit. Over the limit, `vm-claude` says so and skips the copy rather than failing obscurely; trim `CLAUDE_VM_CONFIG_ITEMS` or raise `CLAUDE_VM_CONFIG_MAX_KB`.

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
| `CLAUDE_VM_CONFIG_MAX_KB` | `120` | Size ceiling for the copied config, in KB |
| `CLAUDE_VM_SETTINGS_STRIP` | `hooks statusLine` | Space-separated `settings.json` keys to drop in the guest; `""` keeps everything |
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

### Ceilings

CPU and RAM grow live only up to a ceiling fixed when the VM booted, and that ceiling defaults to the VM's starting size — so a VM booted without `--max-*` can be resized down but not up. Ask for headroom the first time:

```bash
vm-claude --cpus 2 --memory 4G --max-cpus 8 --max-memory 32G
```

It's a limit, not a reservation: it costs nothing until claimed, so set it generously. Raising it later works too, at the price of one reboot. `msb ps` shows the current allocation as `effective / max`.

The root disk only ever grows. Shrinking it isn't possible — the only way down is `--rm` and a fresh VM.

A refused resize — no headroom, a shrink, or an `msb` too old to have `modify` — is reported, and the session continues at the VM's current size. It never blocks the run. `--resize` on a project with no VM yet does nothing, since a fresh boot already uses whatever sizes you passed.

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

## Notes and caveats

- **Sign-in is per project.** Because state lives in the per-project VM disk, the first run in each new project asks you to authenticate again. Credentials are never copied from the host — only the config allowlist is. `--rm` resets that.
- **The VM has network access**, which is what makes `npm install` and the Claude API work. Isolation here is about the filesystem, not the network.
- **Only `/workspace` persists on the host.** Anything Claude writes elsewhere in the guest lives in the VM disk and disappears with `--rm`.
- **`claude` is (re)installed on every start and resume**, so each session picks up the newest release (`CLAUDE_VM_VERSION` defaults to `latest`). On a resume the update is best-effort — if the install fails (e.g. no network), the version already in the VM is used and the session still starts. Pin `CLAUDE_VM_VERSION` to a specific version to hold `claude` steady across sessions.
- Upstream docs: <https://docs.microsandbox.dev/examples/agents/claude-code>
