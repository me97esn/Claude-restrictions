#!/usr/bin/env bash
# Installs the team's Claude Code restrictions on Linux / WSL2 / macOS:
#   - the PreToolUse hook  -> /usr/local/bin/claude-guard.sh
#   - managed settings     -> /etc/claude-code/managed-settings.json (Linux)
#                             /Library/Application Support/ClaudeCode/managed-settings.json (macOS)
#
# Usage: ./install.sh   (asks for sudo if needed)
#
# Set DESTDIR to install into a staging directory instead (no root needed),
# e.g. DESTDIR=/tmp/stage ./install.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DESTDIR=${DESTDIR:-}

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux)  OS=linux;  SETTINGS_DIR=/etc/claude-code ;;
  Darwin) OS=macos;  SETTINGS_DIR="/Library/Application Support/ClaudeCode" ;;
  *)      die "Unsupported OS: $(uname -s). Use Linux, WSL2 or macOS." ;;
esac
HOOK_PATH=/usr/local/bin/claude-guard.sh

if [[ -z $DESTDIR && $EUID -ne 0 ]]; then
  info "Root is needed to write managed settings. Re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

# The user who ran the script (not root), used for sandbox checks
REAL_USER=${SUDO_USER:-$(id -un)}

# --- Dependencies ------------------------------------------------------------

missing=()
command -v jq >/dev/null 2>&1 || missing+=(jq)
if [[ $OS == linux ]]; then
  command -v bwrap >/dev/null 2>&1 || missing+=(bubblewrap)
  command -v socat >/dev/null 2>&1 || missing+=(socat)
fi

if (( ${#missing[@]} )); then
  if [[ -n $DESTDIR ]]; then
    warn "Missing dependencies (not installed in DESTDIR mode): ${missing[*]}"
  elif [[ $OS == linux ]] && command -v apt-get >/dev/null 2>&1; then
    info "Installing ${missing[*]}..."
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
  elif [[ $OS == linux ]] && command -v dnf >/dev/null 2>&1; then
    info "Installing ${missing[*]}..."
    dnf install -y -q "${missing[@]}"
  elif [[ $OS == macos ]] && sudo -u "$REAL_USER" bash -lc 'command -v brew' >/dev/null 2>&1; then
    info "Installing ${missing[*]} with Homebrew..."
    sudo -u "$REAL_USER" bash -lc "brew install ${missing[*]}"
  else
    die "Please install these first: ${missing[*]}"
  fi
fi

# --- Sandbox check (Linux) ---------------------------------------------------

if [[ $OS == linux && -z $DESTDIR ]]; then
  if ! sudo -u "$REAL_USER" bwrap --ro-bind / / --dev /dev --proc /proc true 2>/dev/null; then
    warn "bubblewrap cannot create a sandbox for $REAL_USER on this machine."
    warn "On Ubuntu 24.04+ this is usually AppArmor restricting user namespaces."
    warn "Because failIfUnavailable is true, Claude Code will refuse to run Bash until this is fixed."
    warn "See https://code.claude.com/docs/en/sandboxing"
  fi
fi

# --- Paths to protect --------------------------------------------------------

# Directories Claude must never read (browser sessions, CLI credentials).
# "~" is kept literal: managed settings apply to every user on the machine.
protected_dirs=("~/.azure" "~/.ssh" "~/.kube")
if [[ $OS == linux ]]; then
  protected_dirs+=(
    "~/.mozilla"
    "~/.config/google-chrome"
    "~/.config/chromium"
    "~/.config/microsoft-edge"
  )
else
  protected_dirs+=(
    "~/Library/Application Support/Firefox"
    "~/Library/Application Support/Google/Chrome"
    "~/Library/Application Support/Microsoft Edge"
    "~/Library/Cookies"
  )
fi

# --- Build managed settings --------------------------------------------------

settings=$(jq -n --args '
  ($ARGS.positional) as $dirs |
  {
    permissions: {
      deny: (
        ["Read(**/.env)", "Read(**/.env.*)", "Read(!**/.env.in)"]
        + ($dirs | map("Read(\(.)/**)"))
        + ["Bash(git push --force:*)", "Bash(git push -f:*)", "Bash(git push --force-with-lease:*)"]
      )
    },
    hooks: {
      PreToolUse: [
        { matcher: "Bash", hooks: [ { type: "command", command: "'"$HOOK_PATH"'" } ] }
      ]
    },
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      filesystem: {
        denyRead: (["~/**/.env", "~/**/.env.*"] + $dirs),
        allowRead: ["~/**/.env.in"]
      }
    }
  }' "${protected_dirs[@]}")

# --- Install -----------------------------------------------------------------

info "Installing hook to $DESTDIR$HOOK_PATH"
mkdir -p "$DESTDIR$(dirname "$HOOK_PATH")"
install -m 755 "$SCRIPT_DIR/claude-guard.sh" "$DESTDIR$HOOK_PATH"

target="$DESTDIR$SETTINGS_DIR/managed-settings.json"
mkdir -p "$DESTDIR$SETTINGS_DIR"
if [[ -f $target ]]; then
  if [[ $(cat "$target") == "$settings" ]]; then
    info "Managed settings already up to date"
  else
    backup="$target.bak.$(date +%Y%m%d-%H%M%S)"
    warn "Existing managed settings found, backing up to $backup"
    cp "$target" "$backup"
  fi
fi
info "Writing managed settings to $target"
printf '%s\n' "$settings" > "$target"
chmod 644 "$target"

# --- Self-test ---------------------------------------------------------------

info "Testing hook..."
fail=0
check() {
  local expected=$1 command=$2 actual=0
  jq -nc --arg c "$command" '{tool_input: {command: $c}}' \
    | "$DESTDIR$HOOK_PATH" 2>/dev/null || actual=$?
  if [[ $actual -ne $expected ]]; then
    warn "Hook returned $actual (expected $expected) for: $command"
    fail=1
  fi
}
check 2 'cat .env'
check 2 'git push --force origin main'
check 2 'git push origin +main'
check 0 'cat .env.example'
check 0 'cat .env.in'
check 2 'cat .env.internal'
check 2 'cat .env.in.local'
check 2 'cat .env.in .env'
check 0 'git push origin main'
check 0 'ls -la'
(( fail )) && die "Hook self-test failed"

info "Done. Restart any running Claude Code sessions to load the new settings."
info "Verify with /permissions inside Claude Code."
