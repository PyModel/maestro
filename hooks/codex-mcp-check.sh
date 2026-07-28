#!/usr/bin/env bash
# Maestro MCP check — shows exactly which MCP servers Codex background jobs
# (discussion loop + implementer) will inherit, by reading the same config they
# read: ~/.codex/config.toml. Also reports the built-in web_search setting
# (disabled by Maestro on purpose — MCP servers are unaffected by it).
#
# Usage: codex-mcp-check.sh
# Exit codes: 0 = at least one MCP server configured | 3 = none found / no config
set -uo pipefail

CODEX_CONF="$HOME/.codex/config.toml"

if [ ! -f "$CODEX_CONF" ]; then
  echo "MCP_CHECK: no ~/.codex/config.toml — background Codex jobs get no MCP servers."
  echo 'Configure [mcp_servers.<name>] tables there (the same config file the codex CLI uses).'
  exit 3
fi

echo "=== MCP servers in ~/.codex/config.toml (inherited by every Maestro Codex job) ==="
SERVERS=$(grep -oE '^\[mcp_servers\.[^]]+\]' "$CODEX_CONF" | sed 's/^\[mcp_servers\.//; s/\]$//' || true)

if [ -z "$SERVERS" ]; then
  echo "(none found)"
  echo
  echo "MCP_CHECK: no [mcp_servers.*] tables. Add e.g.:"
  echo '  [mcp_servers.tavily]'
  echo '  command = "npx"'
  echo '  args = ["-y", "tavily-mcp@latest"]'
  echo '  env = { TAVILY_API_KEY = "..." }'
  exit 3
fi

printf '%s\n' "$SERVERS" | while read -r name; do
  echo "  • $name"
done

echo
echo "=== env keys declared per server (values masked) ==="
awk '
  /^\[mcp_servers\.[^]]+\]/ {
    match($0, /\[mcp_servers\.[^]]+\]/)
    cur = substr($0, RSTART + 13, RLENGTH - 14); next
  }
  /^\[/ { cur="" }
  cur != "" && /^[[:space:]]*env[[:space:]]*=/ {
    line=$0
    sub(/^[[:space:]]*env[[:space:]]*=[[:space:]]*\{?/, "", line)
    while (match(line, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)) {
      key=substr(line, RSTART, RLENGTH)
      gsub(/[[:space:]=]/, "", key)
      print "  " cur ": " key " = ****"
      line=substr(line, RSTART + RLENGTH)
    }
  }
' "$CODEX_CONF"

echo
WS=$(awk -F'"' '/^\[/{exit} /^[[:space:]]*web_search[[:space:]]*=/{print $2}' "$CODEX_CONF" | tail -1)
echo "=== built-in web_search: ${WS:-(Codex default)} — Maestro disables this on purpose; MCP servers are unaffected ==="

echo
echo "Note: keys listed above resolve from the config's env tables. Keys your MCP config"
echo "expects from the SHELL (e.g. exported TAVILY_API_KEY) must be exported in the shell"
echo "that launches Claude Code — background jobs inherit that environment."
echo "Live verification: run one discussion turn and watch for 'verified via <mcp>' in the reply."
