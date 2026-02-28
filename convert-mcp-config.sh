#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH=""
OUTPUT_PATH=""
VSCODE_PATH=""
COPILOT_PATH=""
DIRECTION=""
USER_HOME="${HOME}"

usage() {
  cat <<'EOF'
Usage: ./convert-mcp-config.sh [options]

Options:
    -i, --input PATH       Legacy input path (direction-aware)
    -o, --output PATH      Legacy output path (direction-aware)
            --vscode-path PATH Explicit VS Code MCP config path
            --copilot-path PATH Explicit Copilot CLI MCP config path
    -d, --direction MODE   Sync direction: vscode-to-copilot | copilot-to-vscode | keep-in-sync
  -u, --user-home PATH   Override user home path (default: $HOME)
  -h, --help             Show this help

Defaults:
  - Input auto-detect order:
      1) ./mcp.json
      2) ./.vscode/mcp.json
      3) macOS: ~/Library/Application Support/Code/User/mcp.json
      4) Linux: ~/.config/Code/User/mcp.json
    - Copilot path:
            ~/.copilot/mcp-config.json

If --direction is omitted, the script will prompt interactively.
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
        --vscode-path)
            VSCODE_PATH="${2:-}"
            shift 2
            ;;
        --copilot-path)
            COPILOT_PATH="${2:-}"
            shift 2
            ;;
        -d|--direction)
            DIRECTION="${2:-}"
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

python3 - "$INPUT_PATH" "$OUTPUT_PATH" "$USER_HOME" "$VSCODE_PATH" "$COPILOT_PATH" "$DIRECTION" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

input_arg = (sys.argv[1] or "").strip()
output_arg = (sys.argv[2] or "").strip()
user_home = Path((sys.argv[3] or "").strip() or Path.home())
vscode_arg = (sys.argv[4] or "").strip()
copilot_arg = (sys.argv[5] or "").strip()
direction_arg = (sys.argv[6] or "").strip().lower()


def default_vscode_path(home: Path):
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


def default_copilot_path(home: Path):
    return home / ".copilot" / "mcp-config.json"


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


def convert_string(value: str, target: str, env_vars: set[str]):
    result = value

    if target == "copilot":
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

    def repl_plain(match):
        env_name = match.group(1)
        env_vars.add(env_name)
        return f"${{env:{env_name}}}"

    result = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", repl_plain, result)
    return result


def convert_value(value, target: str, env_vars: set[str]):
    if value is None:
        return None

    if isinstance(value, str):
        return convert_string(value, target, env_vars)

    if isinstance(value, list):
        return [convert_value(v, target, env_vars) for v in value]

    if isinstance(value, dict):
        return {k: convert_value(v, target, env_vars) for k, v in value.items()}

    return value


def parse_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as ex:
        raise SystemExit(
            f"Failed to parse JSON from '{path}'. Ensure it's valid JSON (not JSONC). Details: {ex}"
        )


def get_servers_object(parsed: dict):
    if not isinstance(parsed, dict):
        raise SystemExit("Config file root must be a JSON object.")
    source_servers = parsed.get("servers")
    if isinstance(source_servers, dict):
        return source_servers
    source_servers = parsed.get("mcpServers")
    if isinstance(source_servers, dict):
        return source_servers
    raise SystemExit("Input must contain a top-level 'servers' or 'mcpServers' object.")


def unique_name(base: str, target: dict):
    candidate = base
    suffix = 1
    while candidate in target:
        suffix += 1
        candidate = f"{base}_{suffix}"
    return candidate


def convert_servers(source_servers: dict, target: str):
    target_servers: dict[str, dict] = {}

    for original_name, server_obj in source_servers.items():
        if not isinstance(server_obj, dict):
            raise SystemExit(f"Server '{original_name}' is not an object.")

        if target == "copilot":
            base_name = normalize_server_name(original_name)
        else:
            base_name = original_name

        name_to_use = unique_name(base_name, target_servers)
        env_vars: set[str] = set()
        converted_server = convert_value(server_obj, target, env_vars)

        env_obj = converted_server.get("env")
        if env_obj is None:
            env_obj = {}
            converted_server["env"] = env_obj
        elif not isinstance(env_obj, dict):
            raise SystemExit(f"Server '{original_name}' has a non-object 'env' field.")

        for env_var in sorted(env_vars):
            if target == "copilot":
                env_obj.setdefault(env_var, f"${env_var}")
            else:
                env_obj.setdefault(env_var, f"${{env:{env_var}}}")

        if not env_obj:
            converted_server.pop("env", None)

        target_servers[name_to_use] = converted_server

    return target_servers


def merge_servers(existing: dict, incoming: dict, target: str):
    result = dict(existing)
    added = 0
    renamed = 0
    unchanged = 0

    for name, value in incoming.items():
        if name not in result:
            result[name] = value
            added += 1
            continue

        if json.dumps(result[name], sort_keys=True) == json.dumps(value, sort_keys=True):
            unchanged += 1
            continue

        base_name = normalize_server_name(name) if target == "copilot" else name
        new_name = unique_name(base_name, result)
        result[new_name] = value
        added += 1
        renamed += 1

    return result, added, renamed, unchanged


def write_config(path: Path, target: str, servers: dict):
    if target == "copilot":
        payload = {"mcpServers": servers}
    else:
        payload = {"servers": servers}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def resolve_direction(provided: str):
    if provided:
        mapping = {
            "vscode-to-copilot": "vscode-to-copilot",
            "copilot-to-vscode": "copilot-to-vscode",
            "keep-in-sync": "keep-in-sync",
        }
        if provided not in mapping:
            raise SystemExit(
                "Invalid direction. Use: vscode-to-copilot, copilot-to-vscode, or keep-in-sync."
            )
        return mapping[provided]

    print("Select sync direction:")
    print("  1) VS Code -> Copilot CLI")
    print("  2) Copilot CLI -> VS Code")
    print("  3) Keep both in sync")
    choice = input("Enter 1, 2, or 3: ").strip()
    if choice == "1":
        return "vscode-to-copilot"
    if choice == "2":
        return "copilot-to-vscode"
    if choice == "3":
        return "keep-in-sync"
    raise SystemExit(f"Invalid choice '{choice}'.")


direction = resolve_direction(direction_arg)

resolved_vscode = vscode_arg
resolved_copilot = copilot_arg

if not resolved_vscode and input_arg:
    resolved_vscode = input_arg
if not resolved_copilot and output_arg:
    resolved_copilot = output_arg

if direction == "copilot-to-vscode":
    if not resolved_copilot and input_arg:
        resolved_copilot = input_arg
    if not resolved_vscode and output_arg:
        resolved_vscode = output_arg

vscode_path = Path(resolved_vscode) if resolved_vscode else default_vscode_path(user_home)
copilot_path = Path(resolved_copilot) if resolved_copilot else default_copilot_path(user_home)

if vscode_path is None:
    raise SystemExit("Could not auto-detect a VS Code MCP config. Pass --vscode-path explicitly.")

print(f"Direction   : {direction}")
print(f"VS Code path: {vscode_path}")
print(f"Copilot path: {copilot_path}")

has_vscode = vscode_path.exists()
has_copilot = copilot_path.exists()

if direction == "vscode-to-copilot":
    if not has_vscode:
        raise SystemExit(f"Input file not found: {vscode_path}")

    source = get_servers_object(parse_json(vscode_path))
    incoming = convert_servers(source, "copilot")
    existing = get_servers_object(parse_json(copilot_path)) if has_copilot else {}

    merged, added, renamed, unchanged = merge_servers(existing, incoming, "copilot")
    write_config(copilot_path, "copilot", merged)
    print(f"Merged MCP config written to: {copilot_path}")
    print(f"Added servers: {added}; renamed due to conflicts: {renamed}; unchanged duplicates: {unchanged}")
    raise SystemExit(0)

if direction == "copilot-to-vscode":
    if not has_copilot:
        raise SystemExit(f"Input file not found: {copilot_path}")

    source = get_servers_object(parse_json(copilot_path))
    incoming = convert_servers(source, "vscode")
    existing = get_servers_object(parse_json(vscode_path)) if has_vscode else {}

    merged, added, renamed, unchanged = merge_servers(existing, incoming, "vscode")
    write_config(vscode_path, "vscode", merged)
    print(f"Merged MCP config written to: {vscode_path}")
    print(f"Added servers: {added}; renamed due to conflicts: {renamed}; unchanged duplicates: {unchanged}")
    raise SystemExit(0)

vscode_servers = get_servers_object(parse_json(vscode_path)) if has_vscode else {}
copilot_servers = get_servers_object(parse_json(copilot_path)) if has_copilot else {}

from_vscode = convert_servers(vscode_servers, "copilot")
merged_copilot, added, renamed, unchanged = merge_servers(copilot_servers, from_vscode, "copilot")
final_vscode = convert_servers(merged_copilot, "vscode")

write_config(copilot_path, "copilot", merged_copilot)
write_config(vscode_path, "vscode", final_vscode)

print("Synchronized both files:")
print(f"  VS Code : {vscode_path}")
print(f"  Copilot : {copilot_path}")
print(f"Copilot merge added: {added}; renamed due to conflicts: {renamed}; unchanged duplicates: {unchanged}")
PY
