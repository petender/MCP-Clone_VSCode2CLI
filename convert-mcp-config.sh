#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH=""
OUTPUT_PATH=""
USER_HOME="${HOME}"

usage() {
  cat <<'EOF'
Usage: ./convert-mcp-config.sh [options]

Options:
  -i, --input PATH       Input VS Code MCP config path
  -o, --output PATH      Output Copilot CLI MCP config path
  -u, --user-home PATH   Override user home path (default: $HOME)
  -h, --help             Show this help

Defaults:
  - Input auto-detect order:
      1) ./mcp.json
      2) ./.vscode/mcp.json
      3) macOS: ~/Library/Application Support/Code/User/mcp.json
      4) Linux: ~/.config/Code/User/mcp.json
  - Output:
      ~/.copilot/mcp-config.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      INPUT_PATH="${2:-}"
      shift 2
      ;;
    -o|--output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    -u|--user-home)
      USER_HOME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required but was not found in PATH." >&2
  exit 1
fi

python3 - "$INPUT_PATH" "$OUTPUT_PATH" "$USER_HOME" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

input_arg = (sys.argv[1] or "").strip()
output_arg = (sys.argv[2] or "").strip()
user_home = Path((sys.argv[3] or "").strip() or Path.home())


def default_input_path(home: Path):
    candidates = [
        Path.cwd() / "mcp.json",
        Path.cwd() / ".vscode" / "mcp.json",
    ]

    if sys.platform == "darwin":
        candidates.append(home / "Library" / "Application Support" / "Code" / "User" / "mcp.json")
    else:
        candidates.append(home / ".config" / "Code" / "User" / "mcp.json")

    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def normalize_env_name(name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9_]", "_", name).upper()
    if not normalized:
        raise ValueError(f"Cannot normalize environment variable name from '{name}'.")
    return normalized


def normalize_server_name(name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9_-]", "_", name).strip("_")
    if not normalized:
        raise ValueError(f"Cannot normalize server name from '{name}'.")
    return normalized


def convert_value(value, env_vars: set[str]):
    if value is None:
        return None

    if isinstance(value, str):
        result = value

        def repl_input(match):
            env_name = normalize_env_name(match.group(1))
            env_vars.add(env_name)
            return f"${env_name}"

        def repl_env(match):
            env_name = normalize_env_name(match.group(1))
            env_vars.add(env_name)
            return f"${env_name}"

        result = re.sub(r"\$\{input:([^}]+)\}", repl_input, result)
        result = re.sub(r"\$\{env:([^}]+)\}", repl_env, result)
        return result

    if isinstance(value, list):
        return [convert_value(v, env_vars) for v in value]

    if isinstance(value, dict):
        return {k: convert_value(v, env_vars) for k, v in value.items()}

    return value


input_path = Path(input_arg) if input_arg else default_input_path(user_home)
if input_path is None:
    raise SystemExit("Could not auto-detect a VS Code MCP config. Pass --input explicitly.")

if not input_path.exists():
    raise SystemExit(f"Input file not found: {input_path}")

output_path = Path(output_arg) if output_arg else (user_home / ".copilot" / "mcp-config.json")

print(f"Using input : {input_path}")
print(f"Using output: {output_path}")

raw = input_path.read_text(encoding="utf-8")
try:
    parsed = json.loads(raw)
except json.JSONDecodeError as ex:
    raise SystemExit(
        f"Failed to parse JSON from '{input_path}'. Ensure it's valid JSON (not JSONC). Details: {ex}"
    )

source_servers = parsed.get("servers") or parsed.get("mcpServers")
if not isinstance(source_servers, dict):
    raise SystemExit("Input must contain a top-level 'servers' or 'mcpServers' object.")

target_servers: dict[str, dict] = {}
for original_name, server_obj in source_servers.items():
    if not isinstance(server_obj, dict):
        raise SystemExit(f"Server '{original_name}' is not an object.")

    safe_name = normalize_server_name(original_name)
    name_to_use = safe_name
    suffix = 1
    while name_to_use in target_servers:
        suffix += 1
        name_to_use = f"{safe_name}_{suffix}"

    env_vars: set[str] = set()
    converted_server = convert_value(server_obj, env_vars)

    env_obj = converted_server.get("env")
    if env_obj is None:
        env_obj = {}
        converted_server["env"] = env_obj
    elif not isinstance(env_obj, dict):
        raise SystemExit(f"Server '{original_name}' has a non-object 'env' field.")

    for env_var in sorted(env_vars):
        env_obj.setdefault(env_var, f"${env_var}")

    if not env_obj:
        converted_server.pop("env", None)

    target_servers[name_to_use] = converted_server

output = {"mcpServers": target_servers}
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(output, indent=2), encoding="utf-8")
print(f"Converted MCP config written to: {output_path}")
PY
