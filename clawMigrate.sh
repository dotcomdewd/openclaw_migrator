#!/usr/bin/env bash
set -Eeuo pipefail

# openclaw-migrate.sh
#
# Usage:
#   On OLD system:
#     ./openclaw-migrate.sh export
#
#   Copy the resulting archive to the NEW system, then:
#     ./openclaw-migrate.sh import ./openclaw-migration-YYYYMMDD-HHMMSS.tar.gz
#
# Optional:
#   ./openclaw-migrate.sh export --include "/opt/openclaw,/srv/openclaw"
#   ./openclaw-migrate.sh import ./archive.tar.gz --install-method installer
#   ./openclaw-migrate.sh import ./archive.tar.gz --install-method npm
#
# Notes:
#   - Designed for Linux/WSL2 hosts using systemd user services.
#   - Run as the user that owns/runs OpenClaw, not root.
#   - Does not intentionally expose the gateway externally.
#   - Backs up common OpenClaw config/data locations and the systemd user service.

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEFAULT_ARCHIVE="openclaw-migration-${TIMESTAMP}.tar.gz"
STAGING_BASE="${TMPDIR:-/tmp}/openclaw-migrate-${TIMESTAMP}"
INSTALL_METHOD="installer"
EXTRA_INCLUDE_PATHS=""

COMMON_PATHS=(
  "$HOME/.openclaw"
  "$HOME/.config/openclaw"
  "$HOME/.local/share/openclaw"
  "$HOME/.local/state/openclaw"
  "$HOME/.cache/openclaw"
  "$HOME/.config/systemd/user/openclaw-gateway.service"
  "$HOME/.config/systemd/user/default.target.wants/openclaw-gateway.service"
)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME export [--include "/path/one,/path/two"]
  $SCRIPT_NAME import <archive.tar.gz> [--install-method installer|npm]

Examples:
  $SCRIPT_NAME export
  $SCRIPT_NAME export --include "/opt/openclaw,/srv/openclaw"
  $SCRIPT_NAME import ./openclaw-migration-20260502-120000.tar.gz
  $SCRIPT_NAME import ./openclaw-migration-20260502-120000.tar.gz --install-method npm
EOF
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include)
        EXTRA_INCLUDE_PATHS="${2:-}"
        shift 2
        ;;
      --install-method)
        INSTALL_METHOD="${2:-installer}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

install_linux_dependencies() {
  log "Installing base Linux dependencies..."

  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y \
      curl \
      ca-certificates \
      gnupg \
      tar \
      gzip \
      jq \
      lsof \
      procps \
      coreutils \
      findutils
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y \
      curl \
      ca-certificates \
      gnupg2 \
      tar \
      gzip \
      jq \
      lsof \
      procps-ng \
      coreutils \
      findutils
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y \
      curl \
      ca-certificates \
      gnupg2 \
      tar \
      gzip \
      jq \
      lsof \
      procps-ng \
      coreutils \
      findutils
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --needed --noconfirm \
      curl \
      ca-certificates \
      gnupg \
      tar \
      gzip \
      jq \
      lsof \
      procps-ng \
      coreutils \
      findutils
  else
    log "No supported package manager detected. Skipping OS dependency install."
  fi
}

install_openclaw_cli() {
  log "Installing OpenClaw CLI using method: ${INSTALL_METHOD}"

  case "$INSTALL_METHOD" in
    installer)
      # Official installer path. --no-onboard prevents interactive onboarding during migration.
      curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
      ;;
    npm)
      if ! command -v npm >/dev/null 2>&1; then
        die "npm is not installed. Use --install-method installer or install Node/npm first."
      fi
      npm install -g openclaw@latest
      ;;
    *)
      die "Unsupported install method: ${INSTALL_METHOD}. Use installer or npm."
      ;;
  esac

  # Refresh PATH for common npm/global/local installer locations.
  export PATH="$HOME/.openclaw/bin:$HOME/.npm-global/bin:$(npm prefix -g 2>/dev/null || true)/bin:$PATH"

  if ! command -v openclaw >/dev/null 2>&1; then
    cat <<EOF

OpenClaw installed, but 'openclaw' was not found in PATH.

Try opening a new shell or add one of these to ~/.bashrc:

  export PATH="\$HOME/.openclaw/bin:\$PATH"
  export PATH="\$(npm prefix -g)/bin:\$PATH"

EOF
    die "openclaw command not found after install."
  fi

  log "OpenClaw CLI detected: $(command -v openclaw)"
  openclaw --version || true
}

stop_openclaw_service() {
  if command -v systemctl >/dev/null 2>&1; then
    log "Stopping OpenClaw user service if present..."
    systemctl --user stop openclaw-gateway.service >/dev/null 2>&1 || true
  fi

  if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway stop >/dev/null 2>&1 || true
  fi
}

start_openclaw_service() {
  if command -v openclaw >/dev/null 2>&1; then
    log "Installing/reinstalling OpenClaw gateway user service..."
    openclaw gateway install >/dev/null 2>&1 || openclaw onboard --install-daemon || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable openclaw-gateway.service >/dev/null 2>&1 || true
    systemctl --user restart openclaw-gateway.service >/dev/null 2>&1 || true
  fi

  log "Attempting to show OpenClaw gateway status..."
  openclaw gateway status || true
}

enable_lingering_prompt() {
  if command -v loginctl >/dev/null 2>&1; then
    cat <<EOF

Optional but recommended for headless servers:
To allow the OpenClaw user service to run after logout, run:

  sudo loginctl enable-linger "$USER"

EOF
  fi
}

collect_openclaw_metadata() {
  local meta_file="$1"

  {
    echo "timestamp=${TIMESTAMP}"
    echo "user=$(id -un)"
    echo "uid=$(id -u)"
    echo "home=$HOME"
    echo "hostname=$(hostname)"
    echo "os=$(uname -a)"
    echo "shell=${SHELL:-unknown}"
    echo
    echo "openclaw_path=$(command -v openclaw 2>/dev/null || true)"
    echo "openclaw_version=$(openclaw --version 2>/dev/null || true)"
    echo
    echo "node_path=$(command -v node 2>/dev/null || true)"
    echo "node_version=$(node -v 2>/dev/null || true)"
    echo "npm_path=$(command -v npm 2>/dev/null || true)"
    echo "npm_version=$(npm -v 2>/dev/null || true)"
    echo
    echo "systemd_user_status:"
    systemctl --user status openclaw-gateway.service 2>/dev/null || true
    echo
    echo "openclaw_gateway_status:"
    openclaw gateway status 2>/dev/null || true
    echo
    echo "openclaw_doctor:"
    openclaw doctor 2>/dev/null || true
  } > "$meta_file"
}

export_openclaw() {
  parse_common_args "$@"

  need_cmd tar
  need_cmd gzip

  mkdir -p "$STAGING_BASE/rootfs"
  mkdir -p "$STAGING_BASE/metadata"

  log "Preparing OpenClaw migration export..."
  stop_openclaw_service

  collect_openclaw_metadata "$STAGING_BASE/metadata/source-system.txt"

  local manifest="$STAGING_BASE/metadata/manifest.txt"
  : > "$manifest"

  log "Collecting common OpenClaw paths..."

  for path in "${COMMON_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      log "Including: $path"
      echo "$path" >> "$manifest"

      local rel_path
      rel_path="${path#/}"
      mkdir -p "$STAGING_BASE/rootfs/$(dirname "$rel_path")"

      rsync -a \
        --exclude 'node_modules' \
        --exclude '.git' \
        --exclude '*.log' \
        --exclude 'logs' \
        "$path" "$STAGING_BASE/rootfs/$rel_path" 2>/dev/null || \
      cp -a "$path" "$STAGING_BASE/rootfs/$rel_path"
    fi
  done

  if [[ -n "$EXTRA_INCLUDE_PATHS" ]]; then
    IFS=',' read -ra EXTRA_PATHS <<< "$EXTRA_INCLUDE_PATHS"
    for path in "${EXTRA_PATHS[@]}"; do
      path="$(echo "$path" | xargs)"
      if [[ -e "$path" ]]; then
        log "Including extra path: $path"
        echo "$path" >> "$manifest"

        local rel_path
        rel_path="${path#/}"
        mkdir -p "$STAGING_BASE/rootfs/$(dirname "$rel_path")"

        rsync -a \
          --exclude 'node_modules' \
          --exclude '.git' \
          --exclude '*.log' \
          --exclude 'logs' \
          "$path" "$STAGING_BASE/rootfs/$rel_path" 2>/dev/null || \
        cp -a "$path" "$STAGING_BASE/rootfs/$rel_path"
      else
        log "Skipping missing extra path: $path"
      fi
    done
  fi

  log "Creating archive: $DEFAULT_ARCHIVE"
  tar -C "$STAGING_BASE" -czf "$PWD/$DEFAULT_ARCHIVE" .

  log "Restarting OpenClaw service on source system..."
  start_openclaw_service || true

  rm -rf "$STAGING_BASE"

  cat <<EOF

Export complete.

Archive created:
  $PWD/$DEFAULT_ARCHIVE

Copy it to the new system, then run:
  chmod +x $SCRIPT_NAME
  ./$SCRIPT_NAME import ./$DEFAULT_ARCHIVE

EOF
}

backup_existing_new_host_data() {
  local backup_dir="$HOME/openclaw-preimport-backup-${TIMESTAMP}"
  mkdir -p "$backup_dir"

  local backed_up_any=false

  for path in "${COMMON_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      backed_up_any=true
      local rel_path="${path#/}"
      mkdir -p "$backup_dir/$(dirname "$rel_path")"
      log "Backing up existing new-host path before restore: $path"
      cp -a "$path" "$backup_dir/$rel_path"
    fi
  done

  if [[ "$backed_up_any" == true ]]; then
    log "Existing new-host OpenClaw files backed up to: $backup_dir"
  else
    rmdir "$backup_dir" 2>/dev/null || true
  fi
}

restore_archive() {
  local archive="$1"

  [[ -f "$archive" ]] || die "Archive not found: $archive"

  mkdir -p "$STAGING_BASE"
  tar -C "$STAGING_BASE" -xzf "$archive"

  [[ -d "$STAGING_BASE/rootfs" ]] || die "Invalid archive: missing rootfs directory"

  log "Restoring OpenClaw files into / ..."
  cp -a "$STAGING_BASE/rootfs/." /

  rm -rf "$STAGING_BASE"
}

fix_permissions() {
  log "Fixing ownership for restored user files..."

  for path in \
    "$HOME/.openclaw" \
    "$HOME/.config/openclaw" \
    "$HOME/.local/share/openclaw" \
    "$HOME/.local/state/openclaw" \
    "$HOME/.cache/openclaw" \
    "$HOME/.config/systemd/user/openclaw-gateway.service"
  do
    if [[ -e "$path" ]]; then
      chown -R "$USER":"$USER" "$path" 2>/dev/null || true
    fi
  done
}

verify_openclaw() {
  log "Verifying OpenClaw..."

  echo
  echo "OpenClaw version:"
  openclaw --version || true

  echo
  echo "OpenClaw doctor:"
  openclaw doctor || true

  echo
  echo "OpenClaw gateway status:"
  openclaw gateway status || true

  echo
  echo "Listening ports related to OpenClaw, if any:"
  if command -v lsof >/dev/null 2>&1; then
    lsof -i -P -n | grep -i openclaw || true
  fi
}

import_openclaw() {
  local archive="${1:-}"
  [[ -n "$archive" ]] || die "Missing archive path."

  shift || true
  parse_common_args "$@"

  log "Preparing OpenClaw migration import..."
  install_linux_dependencies
  install_openclaw_cli

  stop_openclaw_service
  backup_existing_new_host_data
  restore_archive "$archive"
  fix_permissions

  start_openclaw_service
  verify_openclaw
  enable_lingering_prompt

  cat <<EOF

Import complete.

Recommended final checks:
  openclaw doctor
  openclaw gateway status
  systemctl --user status openclaw-gateway.service

If this is a headless server and the gateway stops after logout, run:
  sudo loginctl enable-linger "$USER"

EOF
}

main() {
  local action="${1:-}"
  shift || true

  case "$action" in
    export)
      export_openclaw "$@"
      ;;
    import)
      import_openclaw "$@"
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "Unknown action: $action"
      ;;
  esac
}

main "$@"
