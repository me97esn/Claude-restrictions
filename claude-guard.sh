#!/usr/bin/env bash
# PreToolUse hook for Claude Code. Reads the tool call as JSON on stdin.
# Exit code 2 blocks the command and shows stderr to Claude.
#
# This only matches the command text, so it is easy to get around. It catches
# accidents; the sandbox (see managed settings) does the real enforcement.

if ! command -v jq >/dev/null 2>&1; then
  echo "Blocked: jq is not installed, so the team policy hook cannot check commands." >&2
  exit 2
fi

cmd=$(jq -r '.tool_input.command // empty')

# Ignore harmless template files
stripped=$(printf '%s' "$cmd" | sed -E 's/\.env\.(example|sample|template)//g')

if printf '%s' "$stripped" | grep -qE '(^|[^[:alnum:]_])\.env([^[:alnum:]_]|$)'; then
  echo "Blocked: accessing .env files is not allowed by team policy." >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])git([[:space:]].*)?[[:space:]]push([[:space:]]|$)' &&
   printf '%s' "$cmd" | grep -qE '[[:space:]](--force|--force-with-lease|--force-if-includes|-[[:alpha:]]*f[[:alpha:]]*|\+[^[:space:]]+)([[:space:]=]|$)'; then
  echo "Blocked: force push is not allowed by team policy." >&2
  exit 2
fi

exit 0
