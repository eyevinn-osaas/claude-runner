# claude-runner

Run headless [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions in a container. You provide a git repository containing an agent team setup (CLAUDE.md, skills, etc.) and a prompt — the runner clones the repo and executes the task.

Built for [Eyevinn Open Source Cloud](https://www.osaas.io).

## Environment Variables

### Required

| Variable | Description |
| --- | --- |
| `SOURCE_URL` | Git repository URL to clone. Append `#branch` for a specific branch. Alias: `GITHUB_URL` |
| `PROMPT` | The task / prompt for Claude to execute |

### Authentication (one required)

| Variable | Description |
| --- | --- |
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude OAuth token (alternative to API key) |

### Optional

| Variable | Description |
| --- | --- |
| `GIT_TOKEN` | Token for cloning private repositories. Alias: `GITHUB_TOKEN`. Works with GitHub PATs and Gitea-style tokens |
| `MODEL` | Model to use (e.g. `claude-sonnet-4-5-20250514`) |
| `MAX_TURNS` | Maximum number of agentic turns |
| `ALLOWEDTOOLS` | Comma-separated list of allowed tools |
| `DISALLOWEDTOOLS` | Comma-separated list of disallowed tools |
| `VERBOSE` | Rich logging (tool calls, tool results, intermediate turns). Enabled by default — the runner streams JSONL events from Claude and formats them into human-readable stdout. Set to `0` or `false` to fall back to plain text (final assistant message only). |
| `RAW_JSON` | Set to `1` or `true` to emit raw JSONL (one JSON event per line) instead of formatted output. Useful for shipping to log aggregators. Requires `VERBOSE` to be on (the default). |
| `SUB_PATH` | Subdirectory within the repo to use as working directory |
| `CONFIG_SVC` | Name of an OSC Application Config Service instance. When set together with `OSC_ACCESS_TOKEN`, environment variables are loaded from the config service before the Claude session starts |
| `OSC_ACCESS_TOKEN` | Open Source Cloud access token. Enables the OSC MCP server and config service integration |
| `CONFIG_API_KEY` | API key for encrypted parameter store. When set alongside `OSC_ACCESS_TOKEN` and `CONFIG_SVC`, secret parameters are decrypted before being injected as environment variables. |
| `OSC_MCP_URL` | Override the OSC MCP server URL. Defaults to `https://mcp.osaas.io/mcp`. Set to `https://ai.svc.{env}.osaas.io/mcp` for dev/stage, or the env-specific equivalent. |

## Usage

### Docker

```bash
docker build -t claude-runner .

docker run --rm \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -e SOURCE_URL="https://github.com/myorg/my-agent-repo" \
  -e PROMPT="Run the daily report task" \
  claude-runner
```

### Private Repository (GitHub)

```bash
docker run --rm \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -e SOURCE_URL="https://github.com/myorg/private-repo" \
  -e GIT_TOKEN="ghp_xxxxxxxxxxxx" \
  -e PROMPT="Analyze the codebase and create a summary" \
  claude-runner
```

### Private Repository (Gitea / self-hosted)

```bash
docker run --rm \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -e SOURCE_URL="https://gitea.example.com/org/repo" \
  -e GIT_TOKEN="your-gitea-token" \
  -e PROMPT="Run the agent team" \
  claude-runner
```

### Specific Branch

```bash
docker run --rm \
  -e ANTHROPIC_API_KEY="sk-ant-..." \
  -e SOURCE_URL="https://github.com/myorg/repo#develop" \
  -e PROMPT="Test the feature branch" \
  claude-runner
```

### Using OAuth Token

```bash
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN="token-here" \
  -e SOURCE_URL="https://github.com/myorg/repo" \
  -e PROMPT="Perform code review" \
  claude-runner
```

## What Goes in the Repository

The cloned repository should contain Claude Code configuration:

- `CLAUDE.md` — Project instructions and context for Claude
- `.claude/` — Optional directory with skills, settings, and agent definitions
- Any source code Claude should work with

## Behavior

1. Validates required environment variables (fails fast if missing)
2. Clones the repository (with token auth for private repos)
3. Optionally navigates to `SUB_PATH`
4. Authenticates the GitHub CLI if a GitHub token is available
5. Runs `claude --print --dangerously-skip-permissions --verbose --output-format stream-json` with the provided prompt
6. Formats the JSONL event stream into human-readable stdout (tool calls, tool results, intermediate turns). Set `RAW_JSON=1` to emit raw JSONL, or `VERBOSE=0` to fall back to plain text output
7. Exits with Claude's exit code

## About Eyevinn Technology

[Eyevinn Technology](https://www.eyevinn.se) is an independent consultant firm specialized in video and streaming. We assist our customers in reducing their expenses and increasing revenue by enhancing the quality of their video and streaming services through innovative and cost-effective solutions.

## License

MIT
