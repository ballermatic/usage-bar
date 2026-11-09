# usage-bar

A macOS menubar readout of AI subscription usage. It shows the server's own percentages, not estimates.

| Provider | Source |
|---|---|
| Claude | `api.anthropic.com/api/oauth/usage` with the Claude Code token in the Keychain |
| Codex | Last `rate_limits` event in the newest `~/.codex/sessions` log (only as fresh as the last Codex run) |
| OpenCode Go | `opencode.ai/zen/go/v1/usage` with the key at Keychain service `dev.pi.opencode-api-key` |
| DeepSeek | `api.deepseek.com/user/balance` (Keychain `dev.pi.deepseek-api-key`) |
| DeepInfra | `api.deepinfra.com/payment/checklist` (Keychain `dev.pi.deepinfra-api-key`); billing state only |

The Claude and OpenCode endpoints are undocumented and may change.

## Install

    scripts/install.sh

This builds a release app, installs it to `~/Applications/Usage Bar.app` and adds it as a login item. The first run asks for Keychain access; choose Always Allow.
