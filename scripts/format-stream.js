#!/usr/bin/env node
// Formats Claude Code `--output-format stream-json` events into
// human-readable stdout. Reads JSONL from stdin, one event per line.
//
// Lines that are not valid JSON are printed through unchanged so this
// stays safe if the upstream accidentally mixes plain text with JSONL.

const readline = require('readline');

const rl = readline.createInterface({ input: process.stdin });

function truncate(s, n) {
  if (typeof s !== 'string') return '';
  if (s.length <= n) return s;
  return s.slice(0, n) + `… [${s.length - n} more chars]`;
}

function formatToolInput(input) {
  if (!input || typeof input !== 'object') return '';
  if (typeof input.command === 'string') return input.command;
  if (typeof input.file_path === 'string') return input.file_path;
  if (typeof input.path === 'string') return input.path;
  if (typeof input.pattern === 'string') return input.pattern;
  if (typeof input.url === 'string') return input.url;
  try {
    return JSON.stringify(input);
  } catch {
    return '';
  }
}

function formatToolResultContent(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((c) => (typeof c === 'string' ? c : c?.text ?? JSON.stringify(c)))
      .join('\n');
  }
  try {
    return JSON.stringify(content);
  } catch {
    return String(content);
  }
}

rl.on('line', (raw) => {
  const line = raw.trim();
  if (!line) return;

  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    console.log(line);
    return;
  }

  switch (evt.type) {
    case 'system': {
      if (evt.subtype === 'init') {
        const model = evt.model || '<default>';
        const session = evt.session_id || '';
        console.log(`[init] model=${model} session=${session}`);
        if (Array.isArray(evt.tools) && evt.tools.length) {
          console.log(`[init] tools=${evt.tools.join(',')}`);
        }
        if (Array.isArray(evt.mcp_servers) && evt.mcp_servers.length) {
          const names = evt.mcp_servers.map((s) => s.name || JSON.stringify(s));
          console.log(`[init] mcp_servers=${names.join(',')}`);
        }
      } else {
        console.log(`[system] ${evt.subtype || ''}`);
      }
      break;
    }

    case 'assistant': {
      const content = evt.message?.content || [];
      for (const c of content) {
        if (c.type === 'text') {
          if (c.text) console.log(c.text);
        } else if (c.type === 'tool_use') {
          const name = c.name || 'tool';
          const arg = formatToolInput(c.input);
          if (arg) {
            console.log(`[tool_use] ${name} — ${truncate(arg, 300)}`);
          } else {
            console.log(`[tool_use] ${name}`);
          }
        } else if (c.type === 'thinking' && c.thinking) {
          console.log(`[thinking] ${truncate(c.thinking, 400)}`);
        }
      }
      break;
    }

    case 'user': {
      const content = evt.message?.content || [];
      for (const c of content) {
        if (c.type === 'tool_result') {
          const body = formatToolResultContent(c.content);
          const tag = c.is_error ? 'tool_error' : 'tool_result';
          console.log(`[${tag}] ${truncate(body, 500)}`);
        }
      }
      break;
    }

    case 'result': {
      const subtype = evt.subtype || '';
      const durSec = typeof evt.duration_ms === 'number'
        ? `${(evt.duration_ms / 1000).toFixed(1)}s`
        : '';
      const cost = typeof evt.total_cost_usd === 'number'
        ? `$${evt.total_cost_usd.toFixed(4)}`
        : '';
      const turns = evt.num_turns !== undefined ? `turns=${evt.num_turns}` : '';
      const parts = [subtype, turns, durSec, cost].filter(Boolean).join(' ');
      console.log(`[result] ${parts}`.trimEnd());
      if (evt.result) {
        console.log('');
        console.log(evt.result);
      }
      break;
    }

    case 'rate_limit_event':
      // Intentionally quiet — too noisy for human-readable output.
      break;

    default:
      console.log(`[${evt.type || 'unknown'}]`);
  }
});

rl.on('close', () => {
  // Let the caller handle the upstream exit code.
});
