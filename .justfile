# vm-claude — task runner. Run `just` to list recipes.
# Install just: `brew install just`

# Where `just install` puts the script (override: `just install_dir=/usr/local/bin install`).
install_dir := env_var_or_default("VM_CLAUDE_INSTALL_DIR", env_var("HOME") + "/.local/bin")

# Show available recipes (default).
default:
    @just --list

# --- Develop -------------------------------------------------------------

# Run the host-only test suite (no VM needed).
test:
    test/run.sh

# Lint the script and the tests with shellcheck.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v shellcheck >/dev/null || { echo "✗ install shellcheck first: brew install shellcheck" >&2; exit 1; }
    bash -n vm-claude
    shellcheck -S warning vm-claude test/run.sh
    echo "✓ lint clean"

# Lint + test: what `just tag` runs before releasing anything.
check: lint test

# --- Install -------------------------------------------------------------

# Install the script from this checkout onto the host.
install:
    install -d "{{install_dir}}"
    install -m 755 vm-claude "{{install_dir}}/vm-claude"
    @echo "✓ Installed $(git describe --tags --always --dirty 2>/dev/null || echo 'vm-claude') to {{install_dir}}/vm-claude"

# Remove the installed script.
uninstall:
    rm -f "{{install_dir}}/vm-claude"
    @echo "✓ Removed {{install_dir}}/vm-claude"

# --- Release -------------------------------------------------------------

# Optional notes (Markdown) go into the annotated tag and the GitHub Release;
# without them the release notes are auto-generated.
# Usage: just tag 1.0.0
#        just tag 1.0.0 "Closes the guest->host git escape."
#        just tag 1.0.0 "$(cat notes.md)"
[doc("Check, tag + push, publish the GitHub Release, then install that version on this host.")]
tag version $notes="":
    #!/usr/bin/env bash
    set -euo pipefail
    ver="{{version}}"
    ver="${ver#v}"
    if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "✗ version must look like 1.1 or 1.1.0 (got '{{version}}')" >&2; exit 1
    fi
    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    if [[ "$branch" != "main" ]]; then
        echo "✗ releases are tagged from main (on '${branch:-detached HEAD}')." >&2; exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "✗ working tree not clean — commit or stash first." >&2; exit 1
    fi
    git fetch --quiet origin main --tags
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
        echo "✗ main is not in sync with origin/main — pull or push first." >&2; exit 1
    fi
    if git rev-parse -q --verify "refs/tags/v$ver" >/dev/null; then
        echo "✗ tag v$ver already exists." >&2; exit 1
    fi
    # Pre-flight: lint and test before anything is tagged or pushed.
    just check
    # `notes` arrives as an environment variable (the `$` on the parameter), so
    # quotes, backticks, and newlines in it pass through untouched.
    if [[ -n "${notes//[[:space:]]/}" ]]; then
        git tag -a "v$ver" --cleanup=verbatim -m "$notes"
    else
        git tag -a "v$ver" -m "v$ver"
    fi
    git push origin "v$ver"
    echo "✓ Pushed v$ver."
    # No CI here, so publish the GitHub Release ourselves, with the script attached.
    if command -v gh >/dev/null; then
        if [[ -n "${notes//[[:space:]]/}" ]]; then
            gh release create "v$ver" vm-claude --verify-tag --title "v$ver" --notes "$notes"
        else
            gh release create "v$ver" vm-claude --verify-tag --title "v$ver" --generate-notes
        fi
        echo "✓ Published the v$ver GitHub Release."
    else
        echo "⚠ gh not installed — tag pushed, but no GitHub Release created (brew install gh)." >&2
    fi
    just install
