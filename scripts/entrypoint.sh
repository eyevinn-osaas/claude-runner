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

# Show repo info
if [ -f "CLAUDE.md" ]; then
  echo "Found CLAUDE.md in repository."
fi
if [ -d ".claude" ]; then
  echo "Found .claude/ directory in repository."
fi

# ------------------------------------------------------------------
# 3. Configure GitHub CLI (if token available)
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
# 4. Configure OSC MCP server (if token available)
# ------------------------------------------------------------------

if [ -n "${OSC_ACCESS_TOKEN:-}" ]; then
  echo "Configuring OSC MCP server..."
  mkdir -p "${HOME}/.claude"
  cat > "${HOME}/.claude/settings.json" <<MCPEOF
{
  "mcpServers": {
    "OSC": {
      "type": "http",
      "url": "https://mcp.osaas.io/mcp",
      "headers": {
        "Authorization": "Bearer ${OSC_ACCESS_TOKEN}"
      }
    }
  }
}
MCPEOF
  echo "OSC MCP server configured (https://mcp.osaas.io/mcp)"
fi

# ------------------------------------------------------------------
# 5. Build the Claude command
# ------------------------------------------------------------------

CLAUDE_ARGS=("--print" "--dangerously-skip-permissions")

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
# 6. Run the Claude session
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

# Run claude with the prompt — all output goes to stdout/stderr
claude "${CLAUDE_ARGS[@]}" "${PROMPT}"

EXIT_CODE=$?

echo ""
echo "=== Claude session ended ==="
echo "Exit code: ${EXIT_CODE}"
echo "Finished at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

exit ${EXIT_CODE}
