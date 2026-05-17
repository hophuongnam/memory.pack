// Memory.Pack shared Node helpers. Imported by .mjs hooks via a relative
// specifier (`./_lib.mjs`, always co-located → portable); never executed
// directly. Leading-underscore name mirrors _lib.sh.
import { existsSync } from 'node:fs';

const SDK_REL = 'node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const SDK_PKG = '@anthropic-ai/claude-agent-sdk/sdk.mjs';

// Resolve an importable specifier for @anthropic-ai/claude-agent-sdk.
// replay.mjs previously hardcoded the macOS Homebrew absolute path, which
// does not exist on Linux. Precedence:
//   1. $CLAUDE_AGENT_SDK explicit override (if the file exists)
//   2. $MEMORY_PACK_HOME-local install (engine-bundled by install.sh)
//   3. known global npm roots (macOS Homebrew, Linux /usr/local, /usr/lib)
//   4. bare package specifier — let Node's resolver / NODE_PATH try last
// `exists` is dependency-injected for testability (default fs.existsSync).
export function resolveSdkSpecifier({ env = process.env, exists = existsSync } = {}) {
  const ovr = env.CLAUDE_AGENT_SDK;
  if (ovr && exists(ovr)) return ovr;

  const candidates = [];
  if (env.MEMORY_PACK_HOME) candidates.push(`${env.MEMORY_PACK_HOME}/${SDK_REL}`);
  candidates.push(
    `/opt/homebrew/lib/${SDK_REL}`, // macOS Homebrew global
    `/usr/local/lib/${SDK_REL}`,    // Linux npm global (common)
    `/usr/lib/${SDK_REL}`,          // Linux npm global (distro)
  );
  for (const c of candidates) if (exists(c)) return c;

  return SDK_PKG;
}
