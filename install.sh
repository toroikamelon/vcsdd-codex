#!/usr/bin/env bash
set -euo pipefail

resolve_script_path() {
  local source="${BASH_SOURCE[0]}"
  while [[ -h "$source" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="${dir}/${source}"
  done
  cd -P "$(dirname "$source")" && pwd
}

# VCSDD Claude Code Plugin Installer
SCRIPT_DIR="$(resolve_script_path)"
PLUGIN_NAME="vcsdd-claude-code"
VERSION="1.0.0"
COMMAND_NAME="$(basename "${0}")"

# Default profile
PROFILE="${VCSDD_INSTALL_PROFILE:-standard}"
LANGUAGE="${VCSDD_INSTALL_LANGUAGE:-}"
MODULES="${VCSDD_INSTALL_MODULES:-}"
TARGET="${VCSDD_INSTALL_TARGET:-claude}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)   PROFILE="$2"; shift 2 ;;
    --language)  LANGUAGE="$2"; shift 2 ;;
    --modules)   MODULES="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: ${COMMAND_NAME} [--profile minimal|standard|strict] [--language rust|python|typescript|go|cpp] [--modules id1,id2,...] [--target claude|codex] [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

echo "VCSDD Claude Code Plugin Installer v${VERSION}"
echo "Profile: ${PROFILE}"
echo "Target: ${TARGET}"
[[ -n "$LANGUAGE" ]] && echo "Language: ${LANGUAGE}"
[[ "$DRY_RUN" == "true" ]] && echo "[DRY RUN MODE - no files will be written]"
echo ""

validate_target() {
  case "$TARGET" in
    claude|codex) ;;
    *)
      echo "Error: --target must be one of: claude, codex"
      exit 1
      ;;
  esac
}

validate_target

# Plugin destination (target-specific)
if [[ "$TARGET" == "claude" ]]; then
  CLAUDE_CONFIG_DIR="${HOME}/.claude"
  if [[ ! -d "$CLAUDE_CONFIG_DIR" ]]; then
    echo "Error: Claude Code config directory not found at ${CLAUDE_CONFIG_DIR}"
    echo "Please ensure Claude Code is installed: https://claude.ai/code"
    exit 1
  fi
  PLUGIN_DIR="${CLAUDE_CONFIG_DIR}/plugins/${PLUGIN_NAME}"
else
  CODEX_HOME_DIR="${CODEX_HOME:-${HOME}/.codex}"
  PLUGIN_DIR="${CODEX_HOME_DIR}/plugins/${PLUGIN_NAME}"
fi

install_module() {
  local src="$1"
  local dest_base="$2"

  if [[ -d "${SCRIPT_DIR}/${src}" ]]; then
    local dest="${dest_base}/${src}"
    [[ "$DRY_RUN" == "false" ]] && mkdir -p "$dest"
    echo "  Installing directory: ${src} -> ${dest}"
    if [[ "$DRY_RUN" == "false" ]]; then
      cp -r "${SCRIPT_DIR}/${src}/." "${dest}/"
    fi
  elif [[ -f "${SCRIPT_DIR}/${src}" ]]; then
    local dest_dir="${dest_base}/$(dirname "${src}")"
    [[ "$DRY_RUN" == "false" ]] && mkdir -p "$dest_dir"
    echo "  Installing file: ${src}"
    if [[ "$DRY_RUN" == "false" ]]; then
      cp "${SCRIPT_DIR}/${src}" "${dest_dir}/"
    fi
  else
    echo "  Warning: ${src} not found, skipping"
  fi
}

echo "Installing VCSDD plugin to: ${PLUGIN_DIR}"
[[ "$DRY_RUN" == "false" ]] && mkdir -p "$PLUGIN_DIR"

# Copy plugin manifest when targeting Claude Code
if [[ "$TARGET" == "claude" ]]; then
  echo "  Installing plugin manifest..."
  [[ "$DRY_RUN" == "false" ]] && cp -r "${SCRIPT_DIR}/.claude-plugin" "${PLUGIN_DIR}/"
fi

echo "Installing profile: ${PROFILE}"

resolver_args=(
  "${SCRIPT_DIR}/scripts/install/resolve-install-plan.js"
  --profile "${PROFILE}"
  --format paths
)

if [[ -n "$LANGUAGE" ]]; then
  echo "Installing language profile: ${LANGUAGE}"
  resolver_args+=(--language "${LANGUAGE}")
fi
if [[ -n "$MODULES" ]]; then
  echo "Installing extra modules: ${MODULES}"
  resolver_args+=(--modules "${MODULES}")
fi

INSTALL_PATHS=()
while IFS= read -r install_path; do
  INSTALL_PATHS+=("$install_path")
done < <(node "${resolver_args[@]}")

for install_path in "${INSTALL_PATHS[@]}"; do
  [[ -n "$install_path" ]] || continue
  install_module "$install_path" "$PLUGIN_DIR"
done

if [[ "$TARGET" == "codex" ]]; then
  CODEX_AGENTS_FILE="${CODEX_HOME_DIR}/AGENTS.md"
  START_MARKER="<!-- vcsdd-managed:start -->"
  END_MARKER="<!-- vcsdd-managed:end -->"
  MANAGED_BLOCK=$(cat <<EOF
${START_MARKER}
# VCSDD workflow (installed by ${PLUGIN_NAME})

VCSDD reference assets are installed at ${PLUGIN_DIR}.

- Use ${PLUGIN_DIR}/commands/ for command playbooks (for example, vcsdd-init.md, vcsdd-spec.md, vcsdd-tdd.md).
- Use ${PLUGIN_DIR}/skills/ for deeper workflow instructions.
- Follow gate checks and phase transitions defined in ${PLUGIN_DIR}/AGENTS.md and ${PLUGIN_DIR}/scripts/lib/vcsdd-state.js.

When a task mentions /vcsdd-*, treat it as an intent to execute the corresponding command playbook in commands/.
${END_MARKER}
EOF
)

  if [[ "$DRY_RUN" == "false" ]]; then
    mkdir -p "${CODEX_HOME_DIR}"
    if [[ -f "$CODEX_AGENTS_FILE" ]]; then
      tmp_file="$(mktemp)"
      awk -v start="$START_MARKER" -v end="$END_MARKER" '
        $0 ~ start {in_block=1; next}
        $0 ~ end {in_block=0; next}
        !in_block {print}
      ' "$CODEX_AGENTS_FILE" > "$tmp_file"
      printf "%s

%s
" "$(cat "$tmp_file")" "$MANAGED_BLOCK" > "$CODEX_AGENTS_FILE"
      rm -f "$tmp_file"
    else
      printf "%s
" "$MANAGED_BLOCK" > "$CODEX_AGENTS_FILE"
    fi
  fi

  echo "  Updated Codex guidance: ${CODEX_AGENTS_FILE}"
fi

echo ""
echo "✅ VCSDD installer completed successfully for target: ${TARGET}"
echo ""
echo "Getting started:"
if [[ "$TARGET" == "claude" ]]; then
  echo "  1. Open a project in Claude Code"
else
  echo "  1. Open a project in Codex"
fi
echo "  2. Run: /vcsdd-init <feature-name> --mode lean"
echo "  3. Run: /vcsdd-spec"
echo "  4. Run: /vcsdd-status"
if [[ "$TARGET" == "codex" ]]; then
  echo "  5. Optional: review ${CODEX_HOME_DIR}/AGENTS.md managed VCSDD block"
fi
echo ""
if [[ "$PROFILE" == "standard" || "$PROFILE" == "strict" ]]; then
  echo "Hooks: Default VCSDD_HOOK_PROFILE=standard (gate enforcement on Write/Edit/Bash heuristics, session hooks, pre-compact)."
  echo ""
fi
if [[ "$PROFILE" == "strict" ]]; then
  echo "Strict hook profile: export VCSDD_HOOK_PROFILE=strict (enables auto-commit hook path; still requires VCSDD_AUTO_COMMIT=true to commit)."
  echo ""
fi
