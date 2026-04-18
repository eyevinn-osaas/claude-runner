FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    curl \
    jq \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    make \
    g++ \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Prepare home directory for node user
RUN mkdir -p /home/node/.claude \
    && chown -R node:node /home/node/.claude

VOLUME /usercontent

WORKDIR /runner
COPY ./scripts ./

RUN chmod +x /runner/*.sh

# Starts as root; entrypoint fixes volume ownership then drops to node
ENTRYPOINT ["/runner/entrypoint.sh"]
