# Agent restrictions for Claude Code

Shared Claude Code settings for the team. They stop Claude from:

- reading `.env` files
- reading browser profiles (session cookies for Canvas, Azure Portal, etc.)
- reading CLI credentials (`~/.azure`, `~/.ssh`, `~/.kube`)
- force pushing

The settings are installed as **managed settings**, which apply to every Claude Code session on the machine, in every repo. Developers cannot override them with user or project settings.

> These settings reduce risk but do not guarantee anything. The real protection is to keep important secrets off developer machines and to protect production on the Azure/Canvas side (PIM, separate admin accounts, short-lived tokens). Also enable force-push protection on the git host.

## What each layer does

| Layer | Blocks | Can it be bypassed? |
|---|---|---|
| `permissions.deny` (`Read(...)`) | Claude's own file tools (Read, Grep, Glob) | No, but it does not cover shell commands |
| Hook (`claude-guard.sh`) | Shell commands that mention `.env` or force push | Yes, easily (e.g. `cat .e''nv`). It catches accidents only |
| Sandbox `filesystem.denyRead` | Any read of the paths by a shell command, enforced by the OS | No, as long as `allowUnsandboxedCommands` is `false` |
| Sandbox network | Outbound traffic to domains that are not allowed | No |

Known side effect: inside the sandbox, commands that need `.env` (e.g. `npm run dev` with dotenv, `node .` in scripts that read `.env`) cannot read it. Run those yourself instead of letting Claude run them.

## Install

Supported: Linux, WSL2 and macOS. Native Windows is not supported (no sandbox), so use WSL2.

```sh
cd claude-restrictions
./install.sh
```

The script asks for `sudo` and then:

1. Installs missing dependencies: `jq` (all platforms), plus `bubblewrap` and `socat` on Linux. It uses `apt`/`dnf` on Linux and Homebrew on macOS.
2. On Linux, checks that bubblewrap can create a sandbox. On Ubuntu 24.04+, AppArmor can block this. Claude Code will then refuse to run Bash until it is fixed, because `failIfUnavailable` is `true`.
3. Installs [`claude-guard.sh`](claude-guard.sh) to `/usr/local/bin/claude-guard.sh`.
4. Writes the managed settings, with browser paths for the current OS:
   - Linux / WSL2: `/etc/claude-code/managed-settings.json`
   - macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`

   If the file already exists with different content, it is backed up first as `managed-settings.json.bak.<timestamp>`.
5. Tests the hook against a few sample commands.

Afterwards, restart any running Claude Code sessions.

Re-run the script after pulling changes to this directory. It is safe to run several times.

To see what would be installed without touching the system:

```sh
DESTDIR=/tmp/stage ./install.sh
cat /tmp/stage/etc/claude-code/managed-settings.json
```

### What gets installed

The generated managed settings (Linux version) look like this:

```json
{
  "permissions": {
    "deny": [
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(~/.azure/**)",
      "Read(~/.ssh/**)",
      "Read(~/.kube/**)",
      "Read(~/.mozilla/**)",
      "Read(~/.config/google-chrome/**)",
      "Read(~/.config/chromium/**)",
      "Read(~/.config/microsoft-edge/**)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git push --force-with-lease:*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/claude-guard.sh" }
        ]
      }
    ]
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "denyRead": [
        "~/**/.env",
        "~/**/.env.*",
        "~/.azure",
        "~/.ssh",
        "~/.kube",
        "~/.mozilla",
        "~/.config/google-chrome",
        "~/.config/chromium",
        "~/.config/microsoft-edge"
      ]
    }
  }
}
```

On macOS, the browser paths are instead `~/Library/Application Support/{Firefox,Google/Chrome,Microsoft Edge}` and `~/Library/Cookies`.

Because `~/.ssh` is blocked, commands Claude runs cannot use your SSH keys. This means Claude cannot `git push`/`pull` over SSH. Run those yourself, or remove `~/.ssh` from the lists in `install.sh` if your team needs it.

To change the rules, edit `install.sh` (paths) or `claude-guard.sh` (hook logic), commit, and ask everyone to re-run `./install.sh`.

## Verify

`install.sh` already tests the hook. To test it by hand:

```sh
echo '{"tool_input":{"command":"cat .env"}}' | /usr/local/bin/claude-guard.sh; echo "exit $?"
# Expected: "Blocked: ..." and exit 2

echo '{"tool_input":{"command":"git push --force origin main"}}' | /usr/local/bin/claude-guard.sh; echo "exit $?"
# Expected: "Blocked: ..." and exit 2

echo '{"tool_input":{"command":"ls -la"}}' | /usr/local/bin/claude-guard.sh; echo "exit $?"
# Expected: exit 0
```

Then, in a repo that has a `.env` file, start `claude` and:

1. Run `/permissions`. The deny rules should be listed.
2. Ask Claude to "read the .env file". It should be blocked.
3. Ask Claude to "run `cat .e''nv`". The hook will not catch this, but the sandbox should block it with a permission error.
4. Ask Claude to "run `ls ~/.azure`". It should be blocked.

## Rolling out to the team

- Every developer runs `./install.sh` once, and again after the rules change.
- If the team is on a Claude Team or Enterprise plan, an admin can paste the generated JSON into **server-managed settings** in the Claude.ai admin console. Then no settings file is needed on each machine, but the hook script must still be installed at `/usr/local/bin/claude-guard.sh`.
- Optional: set `"allowManagedHooksOnly": true` in the managed settings so that only hooks from managed settings run.

## Recommended outside Claude Code

- **Git host:** enable branch protection that disallows force push on shared branches. This is the only rule that also covers people.
- **Azure:** use PIM (just-in-time roles) and separate admin accounts in a separate browser profile, enable Conditional Access token protection, and run `az logout` when you are not using the CLI.
- **Canvas:** use short-lived API tokens with minimal scope. Do not leave admin sessions open on a machine where Claude runs.
- **Claude in Chrome:** do not install the extension in a browser profile that is logged in to Azure Portal or Canvas admin.
- **`.env`:** keep only low-value local/test secrets there, or store `op://` references (1Password CLI) instead of the actual values.

## References

- Sandboxing: https://code.claude.com/docs/en/sandboxing
- Hooks: https://code.claude.com/docs/en/hooks
- Permissions: https://code.claude.com/docs/en/permissions
- Managed settings: https://code.claude.com/docs/en/managed-settings
