# From VS Code MCP to Copilot CLI MCP: A Beginner-Friendly Migration Guide

If you already have MCP servers configured in VS Code, you can reuse most of that setup in GitHub Copilot CLI.

This guide is written for users who are new to MCP and want a copy-paste path that works.

## Which script should I use?

- **Windows users:** use [convert-mcp-config.ps1](convert-mcp-config.ps1)
  - Quick run: `pwsh -ExecutionPolicy Bypass -File ./convert-mcp-config.ps1`

- **macOS/Linux users:** use [convert-mcp-config.sh](convert-mcp-config.sh)
  - First run: `chmod +x ./convert-mcp-config.sh`
  - Quick run: `./convert-mcp-config.sh`

- **Use PowerShell everywhere** if your team wants one script across all platforms.

## What is MCP (in plain English)?

MCP (Model Context Protocol) is a way for AI tools (like VS Code Copilot or Copilot CLI) to connect to external tools and data sources.

Think of MCP servers as “capability plugins” for your AI agent:

- documentation search
- GitHub actions (issues, PRs, code search)
- browser automation
- Azure DevOps access

## What this guide solves

You have a VS Code MCP config (`mcp.json`) and want the same servers in Copilot CLI (`mcp-config.json`).

## File locations

- Workspace-level VS Code MCP config is usually: `./mcp.json` or `./.vscode/mcp.json`
- User-level VS Code MCP config (by platform):
  - Windows: `%APPDATA%\\Code\\User\\mcp.json`
  - macOS: `~/Library/Application Support/Code/User/mcp.json`
  - Linux: `~/.config/Code/User/mcp.json`
- Copilot CLI MCP config (all platforms): `~/.copilot/mcp-config.json`

## Why the files are similar but not identical

Copilot CLI and VS Code share the same MCP idea, but they differ in a few details:

1. Top-level key name:
   - VS Code uses `servers`
   - Copilot CLI uses `mcpServers`

2. Server ID rules in Copilot CLI:
   - only letters, numbers, `_`, and `-`
   - IDs with `/` must be renamed

3. VS Code `inputs` prompts are not used in Copilot CLI MCP config:
   - replace `${input:name}` with environment variables

4. Environment variable reference format differs:
   - VS Code commonly uses `${env:VAR}`
   - Copilot CLI uses `$VAR` and supports explicit `env` mappings

## Your real example: VS Code config

```jsonc
{
  "servers": {
    "pdt_mcp_learn_docs": {
      "url": "https://learn.microsoft.com/api/mcp",
      "type": "http"
    },
    "io.github.github/github-mcp-server": {
      "type": "stdio",
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_PERSONAL_ACCESS_TOKEN=${env:GITHUB_PERSONAL_ACCESS_TOKEN}",
        "ghcr.io/github/github-mcp-server:0.28.1",
        "stdio"
      ],
      "gallery": "https://api.mcp.github.com",
      "version": "0.28.1"
    },
    "microsoft/playwright-mcp": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--browser", "msedge"],
      "gallery": "https://api.mcp.github.com",
      "version": "0.0.1-seed"
    },
    "microsoft/markitdown": {
      "type": "stdio",
      "command": "uvx",
      "args": ["markitdown-mcp==0.0.1a4"],
      "gallery": "https://api.mcp.github.com",
      "version": "1.0.0"
    },
    "ado": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@azure-devops/mcp", "${input:ado_org}"]
    },
    "microsoft/azure-devops-mcp": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@azure-devops/mcp@latest",
        "${input:ado_org}",
        "-d",
        "${input:ado_domain}"
      ],
      "gallery": "https://api.mcp.github.com",
      "version": "1.0.0"
    }
  },
  "inputs": [
    { "id": "token", "type": "promptString", "password": true },
    { "id": "ado_org", "type": "promptString" },
    { "id": "ado_domain", "type": "promptString" }
  ]
}
```

## Compatible output: Copilot CLI config

```json
{
  "mcpServers": {
    "pdt_mcp_learn_docs": {
      "type": "http",
      "url": "https://learn.microsoft.com/api/mcp"
    },
    "io_github_github_mcp_server": {
      "type": "stdio",
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_PERSONAL_ACCESS_TOKEN",
        "ghcr.io/github/github-mcp-server:0.28.1",
        "stdio"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "$GITHUB_PERSONAL_ACCESS_TOKEN"
      },
      "gallery": "https://api.mcp.github.com",
      "version": "0.28.1"
    },
    "microsoft_playwright_mcp": {
      "type": "stdio",
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--browser", "msedge"],
      "gallery": "https://api.mcp.github.com",
      "version": "0.0.1-seed"
    },
    "microsoft_markitdown": {
      "type": "stdio",
      "command": "uvx",
      "args": ["markitdown-mcp==0.0.1a4"],
      "gallery": "https://api.mcp.github.com",
      "version": "1.0.0"
    },
    "ado": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@azure-devops/mcp", "$ADO_ORG"],
      "env": {
        "ADO_ORG": "$ADO_ORG"
      }
    },
    "microsoft_azure_devops_mcp": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@azure-devops/mcp@latest",
        "$ADO_ORG",
        "-d",
        "$ADO_DOMAIN"
      ],
      "env": {
        "ADO_ORG": "$ADO_ORG",
        "ADO_DOMAIN": "$ADO_DOMAIN"
      },
      "gallery": "https://api.mcp.github.com",
      "version": "1.0.0"
    }
  }
}
```

## Fast path (recommended): automate conversion

Use either:

- [convert-mcp-config.ps1](convert-mcp-config.ps1) (PowerShell: Windows/macOS/Linux with `pwsh`)
- [convert-mcp-config.sh](convert-mcp-config.sh) (Bash: macOS/Linux, requires `python3`)

### What the script automatically handles

- `servers` -> `mcpServers`
- drops VS Code-only `inputs`
- converts `${input:name}` to `$NAME`
- converts `${env:VAR}` to `$VAR`
- adds/merges `env` block mappings (`"VAR": "$VAR"`)
- renames invalid server IDs (e.g. containing `/`) to safe IDs

### Run it with PowerShell (`convert-mcp-config.ps1`)

The script now supports cross-platform defaults using your home profile path.

#### Easiest mode (recommended)

If your source file is `./mcp.json` (or `./.vscode/mcp.json`), just run:

```powershell
pwsh -ExecutionPolicy Bypass -File ./convert-mcp-config.ps1
```

This writes to `~/.copilot/mcp-config.json` automatically.

#### Explicit input, default output

```powershell
pwsh -ExecutionPolicy Bypass -File ./convert-mcp-config.ps1 \
  -InputPath ./mcp.json
```

#### Explicit input and output

```powershell
pwsh -ExecutionPolicy Bypass -File ./convert-mcp-config.ps1 \
  -InputPath ./mcp.json \
  -OutputPath ~/.copilot/mcp-config.json
```

#### If you need a custom home path

```powershell
pwsh -ExecutionPolicy Bypass -File ./convert-mcp-config.ps1 \
  -InputPath ./mcp.json \
  -UserHome /home/<user>
```

### Run it with Bash (`convert-mcp-config.sh`)

First-time setup:

```bash
chmod +x ./convert-mcp-config.sh
```

#### Easiest mode (recommended)

```bash
./convert-mcp-config.sh
```

#### Explicit input, default output

```bash
./convert-mcp-config.sh --input ./mcp.json
```

#### Explicit input and output

```bash
./convert-mcp-config.sh --input ./mcp.json --output ~/.copilot/mcp-config.json
```

#### If you need a custom home path

```bash
./convert-mcp-config.sh --input ./mcp.json --user-home /home/<user>
```

#### Prerequisites for Bash version

- `bash`
- `python3`

### Verify the result

In Copilot CLI:

1. `/mcp reload`
2. `/mcp show`

If everything is correct, your servers should appear without config parsing errors.

## Required environment variables for this example

Before launching Copilot CLI, ensure these are set:

- `GITHUB_PERSONAL_ACCESS_TOKEN`
- `ADO_ORG`
- `ADO_DOMAIN`

Example (PowerShell session only):

```powershell
$env:GITHUB_PERSONAL_ACCESS_TOKEN = "<your_token>"
$env:ADO_ORG = "<your_ado_org>"
$env:ADO_DOMAIN = "core"
```

Example (bash/zsh on macOS/Linux):

```bash
export GITHUB_PERSONAL_ACCESS_TOKEN="<your_token>"
export ADO_ORG="<your_ado_org>"
export ADO_DOMAIN="core"
```

## Manual conversion checklist (if you prefer to edit by hand)

- Rename top-level `servers` to `mcpServers`
- Remove `inputs`
- Replace `${input:name}` with `$NAME` env vars
- Replace `${env:VAR}` with `$VAR` and add/update an `env` object
- Replace server IDs containing `/` with `_` or `-`
- Keep operational fields unchanged (`type`, `command`, `args`, `url`, `version`, `gallery`)

## Common errors and fixes

### Error: MCP server name must only contain alphanumeric characters, underscores, and hyphens

Cause: at least one server key contains `/` or another invalid character.

Fix: rename the key, for example:

- `microsoft/playwright-mcp` -> `microsoft_playwright_mcp`

### Server starts but fails at runtime with auth errors

Cause: missing or wrong environment variables.

Fix:

- check variable names match exactly
- confirm values exist in your shell/session
- reload with `/mcp reload`

### Server command not found

Cause: required tool is missing on your machine.

Fix:

- install required tools used in your config (`docker`, `npx`, `uvx`)

## Who is this for?

This guide is useful for:

- developers migrating from VS Code MCP to Copilot CLI
- teams that want one MCP setup style across IDE and terminal
- users who are new to MCP and want an end-to-end starter workflow

## Summary

You can reuse most VS Code MCP configuration in Copilot CLI. The biggest differences are server ID naming rules, top-level key name, and handling of `${input:...}`/`${env:...}` placeholders.

For the best experience, use [convert-mcp-config.ps1](convert-mcp-config.ps1), then run `/mcp reload` and `/mcp show` in Copilot CLI.
