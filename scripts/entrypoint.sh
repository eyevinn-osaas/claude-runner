#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# claude-runner — Run a headless Claude Code session against
# a git repository containing an agent team setup.
# ============================================================

# ------------------------------------------------------------------
# 0. Fix volume ownership (runs as root, then drops to node)
# ------------------------------------------------------------------

if [ "$(id -u)" = "0" ]; then
  chown -R node:node /usercontent
  exec runuser -u node -- "$0" "$@"
fi

echo "=== claude-runner ==="
echo "Starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ------------------------------------------------------------------
# 1. Validate required environment variables
# ------------------------------------------------------------------

# Auth: one of ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN must be set
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "ERROR: Either ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN must be set" >&2
  exit 1
fi

# Source repository URL (required)
SOURCE_URL="${SOURCE_URL:-${GITHUB_URL:-}}"
if [ -z "${SOURCE_URL}" ]; then
  echo "ERROR: SOURCE_URL (or GITHUB_URL) is required — the git repository to clone" >&2
  exit 1
fi

# Prompt / task (required)
PROMPT="${PROMPT:?PROMPT env var is required — the task for Claude to perform}"

# Optional settings
MODEL="${MODEL:-}"
MAX_TURNS="${MAX_TURNS:-}"
ALLOWEDTOOLS="${ALLOWEDTOOLS:-}"
DISALLOWEDTOOLS="${DISALLOWEDTOOLS:-}"
SUB_PATH="${SUB_PATH:-}"

echo "Source:      ${SOURCE_URL}"
echo "Model:       ${MODEL:-<default>}"
echo "Max turns:   ${MAX_TURNS:-<unlimited>}"
echo "Sub path:    ${SUB_PATH:-<root>}"
echo "Auth method: ${ANTHROPIC_API_KEY:+API Key}${CLAUDE_CODE_OAUTH_TOKEN:+OAuth Token}"
echo "===================="

# ------------------------------------------------------------------
# 2. Clone the repository
# ------------------------------------------------------------------

WORK_DIR="/usercontent"

# Parse the source URL — extract host and path for token injection
# Strip any branch ref (fragment after #)
BRANCH=""
if [[ "${SOURCE_URL}" == *"#"* ]]; then
  BRANCH="${SOURCE_URL##*#}"
  SOURCE_URL="${SOURCE_URL%%#*}"
fi

# Determine the git token to use
GIT_TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"

# Build the authenticated clone URL
CLONE_URL="${SOURCE_URL}"
if [ -n "${GIT_TOKEN}" ]; then
  # Strip protocol prefix to rebuild with token
  URL_WITHOUT_PROTO="${SOURCE_URL#https://}"
  URL_WITHOUT_PROTO="${URL_WITHOUT_PROTO#http://}"
  CLONE_URL="https://${GIT_TOKEN}@${URL_WITHOUT_PROTO}"
  echo "Cloning private repository (token injected)..."
else
  echo "Cloning public repository..."
fi

CLONE_ARGS=("--depth" "1")
if [ -n "${BRANCH}" ]; then
  CLONE_ARGS+=("--branch" "${BRANCH}")
  echo "Branch: ${BRANCH}"
fi

git clone "${CLONE_ARGS[@]}" "${CLONE_URL}" "${WORK_DIR}" 2>&1
echo "Repository cloned successfully."

# Navigate to work directory (optionally into sub-path)
if [ -n "${SUB_PATH}" ]; then
  WORK_DIR="${WORK_DIR}/${SUB_PATH}"
  if [ ! -d "${WORK_DIR}" ]; then
    echo "ERROR: SUB_PATH '${SUB_PATH}' does not exist in the repository" >&2
    exit 1
  fi
  echo "Using sub-path: ${SUB_PATH}"
fi

cd "${WORK_DIR}"
echo "Working directory: $(pwd)"

# Set a git identity so Claude can commit without having to run git config mid-session.
git config user.email "agent@claude.ai"
git config user.name "Claude Agent"
echo "Git identity set: Claude Agent <agent@claude.ai>"

# Show repo info
if [ -f "CLAUDE.md" ]; then
  echo "Found CLAUDE.md in repository."
fi
if [ -d ".claude" ]; then
  echo "Found .claude/ directory in repository."
fi

# ------------------------------------------------------------------
# 3. Load environment variables from config service (if available)
# ------------------------------------------------------------------

if [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ]; then
  # Derive OSC environment from OSC_MCP_URL if OSC_ENV is not set explicitly
  if [ -z "${OSC_ENV:-}" ] && [ -n "${OSC_MCP_URL:-}" ]; then
    _extracted=$(echo "${OSC_MCP_URL}" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    if [ -n "${_extracted}" ]; then
      OSC_ENV="${_extracted}"
    else
      OSC_ENV="prod"
    fi
  fi

  # Refresh the access token via the runner token service
  REFRESH_RESULT=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"${OSC_ACCESS_TOKEN}\"}" 2>/dev/null) || true
  if [ -n "${REFRESH_RESULT:-}" ]; then
    FRESH_PAT=$(echo "${REFRESH_RESULT}" | jq -r '.token // empty')
    if [ -n "${FRESH_PAT}" ]; then
      export OSC_ACCESS_TOKEN="${FRESH_PAT}"
      echo "[CONFIG] Refreshed access token via runner refresh token"
    fi
  fi

  echo "[CONFIG] Loading environment variables from config service '${CONFIG_SVC}'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env --env "${OSC_ENV:-prod}" "${CONFIG_SVC}" 2>&1) || true
  config_exit=$?
  if [ ${config_exit} -eq 0 ]; then
    # Only eval lines that are valid shell export statements
    valid_exports=$(echo "${config_env_output}" | grep "^export [A-Za-z_][A-Za-z0-9_]*=" || true)
    if [ -n "${valid_exports}" ]; then
      eval "${valid_exports}"
      var_count=$(echo "${valid_exports}" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded ${var_count} environment variable(s)"
    else
      echo "[CONFIG] WARNING: Config service returned success but no valid export statements."
      echo "[CONFIG] Raw output: ${config_env_output}"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config from '${CONFIG_SVC}' (exit code ${config_exit})."
    echo "[CONFIG] Raw output: ${config_env_output}"
    if echo "${config_env_output}" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Your OSC_ACCESS_TOKEN may have expired. Refresh it and retry."
    fi
  fi
fi

# ------------------------------------------------------------------
# 4. Configure GitHub CLI (if token available)
# ------------------------------------------------------------------

if [ -n "${GIT_TOKEN}" ]; then
  # Configure git to use the token for any subsequent operations
  git config --global url."https://${GIT_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null && \
    echo "GitHub CLI authenticated." || \
    echo "GitHub CLI authentication skipped (token may not be a GitHub PAT)."
fi

# ------------------------------------------------------------------
# 5. Configure OSC MCP server (if token available)
# ------------------------------------------------------------------

if [ -n "${OSC_ACCESS_TOKEN:-}" ]; then
  echo "Configuring OSC MCP server..."
  # Use the Claude Code CLI to register the MCP server at user scope
  # (~/.claude.json). Writing to ~/.claude/settings.json does NOT register
  # MCP servers — that key only exists in ~/.claude.json (user scope) or a
  # project-level .mcp.json. The CLI is the only supported registration path.
  if ! claude mcp add-json --scope user OSC "$(jq -nc \
      --arg url "${OSC_MCP_URL:-https://mcp.osaas.io/mcp}" \
      --arg auth "Bearer ${OSC_ACCESS_TOKEN}" \
      '{type:"http", url:$url, headers:{Authorization:$auth}}')"; then
    echo "ERROR: 'claude mcp add-json' failed to register OSC MCP server" >&2
    exit 1
  fi
  # Verify the server actually registered — catches the class of silent
  # failures where add-json exits 0 but the config didn't stick.
  if ! claude mcp list 2>&1 | grep -q "^OSC"; then
    echo "ERROR: OSC MCP server registration did not stick — 'claude mcp list' did not return OSC" >&2
    exit 1
  fi
  echo "OSC MCP server configured (${OSC_MCP_URL:-https://mcp.osaas.io/mcp})"
fi

# ------------------------------------------------------------------
# 6. Build the Claude command
# ------------------------------------------------------------------

CLAUDE_ARGS=("--print" "--dangerously-skip-permissions")

# Stream JSONL events by default so tool calls, tool results, and
# intermediate assistant turns are visible. A formatter (see step 7)
# turns the JSONL into human-readable stdout. Set VERBOSE=0 to fall
# back to plain text output (final assistant message only).
STREAM_JSON_ENABLED=0
if [ "${VERBOSE:-1}" != "0" ] && [ "${VERBOSE:-1}" != "false" ]; then
  CLAUDE_ARGS+=("--verbose" "--output-format" "stream-json")
  STREAM_JSON_ENABLED=1
fi

if [ -n "${MODEL}" ]; then
  CLAUDE_ARGS+=("--model" "${MODEL}")
fi

if [ -n "${MAX_TURNS}" ]; then
  CLAUDE_ARGS+=("--max-turns" "${MAX_TURNS}")
fi

if [ -n "${ALLOWEDTOOLS}" ]; then
  CLAUDE_ARGS+=("--allowedTools" "${ALLOWEDTOOLS}")
fi

if [ -n "${DISALLOWEDTOOLS}" ]; then
  CLAUDE_ARGS+=("--disallowedTools" "${DISALLOWEDTOOLS}")
fi

# ------------------------------------------------------------------
# 7. Run the Claude session
# ------------------------------------------------------------------

echo ""
echo "=== Claude session starting ==="
echo "Prompt: ${PROMPT}"
echo "================================"
echo ""

# Export auth tokens so Claude CLI can pick them up
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"

# Disable telemetry in CI/container context
export DISABLE_AUTOUPDATER=1

# Run claude with the prompt. When stream-json is enabled (default),
# pipe through the formatter for human-readable stdout. Set RAW_JSON=1
# to skip the formatter and emit raw JSONL (useful for log shipping).
if [ "${STREAM_JSON_ENABLED}" = "1" ] && [ "${RAW_JSON:-}" != "1" ] && [ "${RAW_JSON:-}" != "true" ]; then
  set +e
  claude "${CLAUDE_ARGS[@]}" "${PROMPT}" | node /runner/format-stream.js
  EXIT_CODE=${PIPESTATUS[0]}
  set -e
else
  set +e
  claude "${CLAUDE_ARGS[@]}" "${PROMPT}"
  EXIT_CODE=$?
  set -e
fi

echo ""
echo "=== Claude session ended ==="
echo "Exit code: ${EXIT_CODE}"
echo "Finished at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

exit ${EXIT_CODE}
