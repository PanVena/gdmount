#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Pan Vena
#
# gdmount: Google Drive as a local device | Google Drive як локальний пристрій
# Run locally: ./install.sh
# Install remotely: curl -fsSL https://github.com/PanVena/gdmount/raw/refs/heads/main/install.sh | bash
#
# EN: Downloads your Google Drive (everything, or only chosen folders) to this computer,
#     keeps it in sync with rclone bisync and mounts it as a device named "Google Drive".
#     You always work with local files only: no network drive, no size limits.
# UA: Завантажує ваш Google Drive (весь або лише обрані теки) на комп'ютер, тримає його
#     синхронізованим через rclone bisync і монтує як пристрій «Google Drive».
#     Ви завжди працюєте з локальними файлами: без мережевого диска й обмежень обсягу.
#
# Help / довідка: gdmount --help
# Status / стан: gdmount status
# Uninstall / видалення: gdmount uninstall

set -euo pipefail

# Localization: GDMOUNT_UI_LANG=uk|en. System locale is used by default.
gdmount_detect_lang() {
  local v
  for v in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    [[ -n "$v" ]] || continue
    [[ "${v,,}" == uk* ]] && echo uk || echo en
    return 0
  done
  echo en
}
declare -gA GDMOUNT_EN=()
_() {
  local s="$1"; shift
  if [[ "${GDMOUNT_UI_LANG:-uk}" == en && -n "${GDMOUNT_EN[$s]+x}" ]]; then s="${GDMOUNT_EN[$s]}"; fi
  if (($#)); then printf -- "$s" "$@"; else printf '%s' "$s"; fi
}

GDMOUNT_SOURCE="${BASH_SOURCE[0]:-}"
GDMOUNT_LANG_EXPLICIT=0
[[ -n "${GDMOUNT_UI_LANG:-}" ]] && GDMOUNT_LANG_EXPLICIT=1
if [[ -n "$GDMOUNT_SOURCE" && -f "$GDMOUNT_SOURCE" ]]; then
  GDMOUNT_SCRIPT_DIR="$(cd -- "$(dirname -- "$GDMOUNT_SOURCE")" && pwd)"
  SELF="$(readlink -f "$GDMOUNT_SOURCE")"
else
  GDMOUNT_BOOTSTRAP_DIR="$(mktemp -d)"
  GDMOUNT_SCRIPT_DIR="$GDMOUNT_BOOTSTRAP_DIR"
  SELF="$GDMOUNT_BOOTSTRAP_DIR/install.sh"
  if ! command -v curl >/dev/null 2>&1 ||
    ! curl -fsSL "https://raw.githubusercontent.com/PanVena/gdmount/main/install.sh" -o "$SELF" ||
    ! curl -fsSL "https://raw.githubusercontent.com/PanVena/gdmount/main/i18n.sh" -o "$GDMOUNT_BOOTSTRAP_DIR/i18n.sh"; then
    printf 'gdmount: could not download the installer files required for streamed installation.\n' >&2
    rm -rf -- "$GDMOUNT_BOOTSTRAP_DIR"
    exit 1
  fi
fi
for GDMOUNT_I18N in \
  "$GDMOUNT_SCRIPT_DIR/i18n.sh" \
  "$HOME/.local/share/gdmount/i18n.sh"; do
  if [[ -f "$GDMOUNT_I18N" ]]; then
    # shellcheck disable=SC1090
    source "$GDMOUNT_I18N"
    break
  fi
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
STATE_DIR="$HOME/.config/rclone-gdrive-setup"
CONF_FILE="$STATE_DIR/config"
SYNC_LOCK="$STATE_DIR/sync.lock"
SYNC_LOCKED=0
COMMAND="${1-install}"
if (($#)); then shift; fi
[[ "$COMMAND" == refresh ]] && COMMAND=sync

cleanup() {
  if [[ "${RESTORE_RUNNING_UNITS:-0}" == 1 ]]; then restore_running_units || true; fi
  if [[ -n "${STAGED_RCLONE_CONFIG:-}" ]]; then rm -f -- "$STAGED_RCLONE_CONFIG"; fi
  if [[ -n "${GDMOUNT_BOOTSTRAP_DIR:-}" ]]; then rm -rf -- "$GDMOUNT_BOOTSTRAP_DIR"; fi
}
trap cleanup EXIT

acquire_sync_lock() {
  command -v flock >/dev/null 2>&1 || return 2
  mkdir -p -- "$STATE_DIR" || return 2
  exec {SYNC_LOCK_FD}>>"$SYNC_LOCK" || return 2
  flock -n "$SYNC_LOCK_FD" || return 1
  SYNC_LOCKED=1
}

# Read settings under the same lock used by the timer so a waiting command
# cannot start with a selection or account that was just replaced.
gdmount_lock_required=0
case "$COMMAND" in
  install|sync|start|stop|uninstall|switch-account|switch) gdmount_lock_required=1 ;;
  local|offline) [[ "${1:-}" == add || "${1:-}" == remove || "${1:-}" == -* ]] && gdmount_lock_required=1 ;;
  mode|sync-mode) (($#)) && gdmount_lock_required=1 ;;
esac
case "${1:-}" in -h|--help) gdmount_lock_required=0 ;; esac
if ((gdmount_lock_required)); then
  if acquire_sync_lock; then
    :
  else
    gdmount_lock_result=$?
    if [[ "$COMMAND" == sync && "${1:-}" == --background && $gdmount_lock_result -eq 1 ]]; then exit 0; fi
    GDMOUNT_UI_LANG="${GDMOUNT_UI_LANG:-$(gdmount_detect_lang)}"
    if ((gdmount_lock_result == 1)); then
      _ "Інша команда gdmount уже працює. Повторіть після її завершення." >&2
    else
      _ "Не вдалося заблокувати стан gdmount. Перевірте наявність flock і доступ до %s." "$STATE_DIR" >&2
    fi
    printf '\n' >&2
    exit 1
  fi
elif [[ "$COMMAND" == status && -d "$STATE_DIR" ]]; then
  acquire_sync_lock || true
fi

# Values saved during install (environment variables and flags take priority)
GDMOUNT_REMOTE_OVERRIDE="${GDRIVE_REMOTE:-}"
GDMOUNT_MOUNT_OVERRIDE="${GDRIVE_MOUNT:-}"
unset GDRIVE_REMOTE GDRIVE_MOUNT
# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
CONFIGURED_REMOTE=""
if [[ -f "$CONF_FILE" ]]; then CONFIGURED_REMOTE="${GDRIVE_REMOTE:-gdrive}"; fi
GDMOUNT_UI_LANG="${GDMOUNT_UI_LANG:-${GDRIVE_UI_LANG:-$(gdmount_detect_lang)}}"

REMOTE="${GDMOUNT_REMOTE_OVERRIDE:-${CONFIGURED_REMOTE:-gdrive}}"
CONFIGURED_MOUNT="${GDRIVE_MOUNT:-$HOME/Google Drive}"
MNT="${GDMOUNT_MOUNT_OVERRIDE:-$CONFIGURED_MOUNT}"
MOUNT_NAME="Google Drive"                       # device name (filesystem name)
SYNC_INTERVAL="${GDRIVE_SYNC_INTERVAL:-${GDRIVE_POLL_INTERVAL:-5m}}" # how often auto sync runs
SYNC_MODE="${GDRIVE_SYNC_MODE:-${GDRIVE_SYNC_METHOD:-}}"             # manual or auto
# Keep the old refresh-mode setting working when upgrading from the previous
# network-mount implementation. A version-3 config was created by the current
# local-copy implementation, so preserve its automatic timer on first upgrade.
if [[ -z "$SYNC_MODE" ]]; then
  case "${GDRIVE_REFRESH_MODE:-}" in
    manual|auto) SYNC_MODE="$GDRIVE_REFRESH_MODE" ;;
    *)
      if [[ "${GDRIVE_CONF_VERSION:-}" == "3" && -n "${GDRIVE_SYNC_INTERVAL:-}" ]]; then
        SYNC_MODE=auto
      else
        SYNC_MODE=manual
      fi
      ;;
  esac
fi
# A legacy poll interval of zero means that polling was disabled. Keep a valid
# interval in the config so switching back to auto later has a useful default.
if [[ "$SYNC_INTERVAL" =~ ^0+(s|sec|m|min|h|d)?$ ]]; then SYNC_INTERVAL=5m; fi
OFFLINE_DIR="${GDRIVE_OFFLINE_DIR:-$HOME/.local/share/gdmount/offline}"
OFFLINE_ARCHIVE="$HOME/.local/share/gdmount/unselected"
ARCHIVE_ID="${GDRIVE_ARCHIVE_ID:-}"
LEGACY_OFFLINE_DIR=""
if [[ "$OFFLINE_DIR" != "$HOME/.local/share/gdmount/offline" ]]; then
  LEGACY_OFFLINE_DIR="$OFFLINE_DIR"
  OFFLINE_DIR="$HOME/.local/share/gdmount/offline"
fi
OFFLINE_FOLDERS="${GDRIVE_OFFLINE_FOLDERS:-}"   # selected folders (one per line)
OFFLINE_ALL="${GDRIVE_OFFLINE_ALL:-0}"          # 1 = the whole drive
ASSUME_YES=0
MNT_FROM_FLAG=0

VIEW_SERVICE="gdmount-drive.service"
SYNC_SERVICE="gdmount-sync.service"
SYNC_TIMER="gdmount-sync.timer"
UNIT_DIR="$HOME/.config/systemd/user"
VIEW_UNIT_FILE="$UNIT_DIR/$VIEW_SERVICE"
SYNC_UNIT_FILE="$UNIT_DIR/$SYNC_SERVICE"
SYNC_TIMER_FILE="$UNIT_DIR/$SYNC_TIMER"
STATE_FILE="$STATE_DIR/state"            # what exactly this script created
CLI_DIR="$HOME/.local/bin"
CLI_PATH="$CLI_DIR/gdmount"
I18N_DIR="$HOME/.local/share/gdmount"
I18N_PATH="$I18N_DIR/i18n.sh"

# Leftovers of the old scheme (network drive through rclone mount)
LEGACY_RCLONE_SERVICE="rclone-gdrive.service"
LEGACY_WATCH_SERVICE="rclone-gdrive-watch.service"
LEGACY_VIEW_SERVICE="gdmount-drive-view.service"
LEGACY_WATCH_SCRIPT="$HOME/.local/bin/rclone-gdrive-watch"
LEGACY_REMOTE_MNT="$HOME/.local/share/gdmount/remote"
LEGACY_CACHE_DIR="$HOME/.cache/rclone-gdrive"
LEGACY_RC_ENV="$STATE_DIR/rc.env"
LEGACY_RC_ADDR="${GDRIVE_RC_ADDR:-127.0.0.1:5572}"

MODE_ARG=""; SYNC_MODE_ARG=""; BACKGROUND=0
OFFLINE_ACTION=""; OFFLINE_PATH=""
SCOPE_ALL_FLAG=0; SCOPE_FOLDER_FLAGS=()
SYNC_MODE_FROM_FLAG=0; SYNC_INTERVAL_FROM_FLAG=0
# Existing configurations already have an intentional sync policy. Fresh
# installs ask once; non-interactive installs use the power-saving manual mode.
SYNC_SETTINGS_CONFIGURED=0
if [[ -n "${GDRIVE_SYNC_MODE:-}" || -n "${GDRIVE_SYNC_METHOD:-}" ||
      -n "${GDRIVE_REFRESH_MODE:-}" || -n "${GDRIVE_SYNC_INTERVAL:-}" ||
      "${GDRIVE_CONF_VERSION:-}" == "3" ]]; then
  SYNC_SETTINGS_CONFIGURED=1
fi
MIN_RCLONE="1.66.0"   # bisync with --conflict-resolve / --resync-mode
RCLONE_AUTH_PORT=53682

# ---------------------------------------------------------------------------
# Output (every message is a printf format that can be translated; see i18n.sh)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step() { local m; m="$(_ "$@")"; echo; echo "${C_BOLD}${C_BLUE}==> $m${C_RESET}"; }
info() { local m; m="$(_ "$@")"; echo "    $m"; }
ok()   { local m; m="$(_ "$@")"; echo "    ${C_GREEN}✔${C_RESET} $m"; }
warn() { local m; m="$(_ "$@")"; echo "    ${C_YELLOW}!${C_RESET} $m"; }
err()  { local m; m="$(_ "$@")"; echo "${C_RED}✘ $m${C_RESET}" >&2; }
die()  { err "$@"; exit 1; }

has_terminal() { { : </dev/tty; } 2>/dev/null; }

read_input() {
  local terminal_fd result=0
  { exec {terminal_fd}</dev/tty; } 2>/dev/null || return 1
  IFS= read -r -p "$1" REPLY <&"$terminal_fd" || result=$?
  exec {terminal_fd}<&-
  return "$result"
}

ask() {
  # ask "Question?" -> 0 for yes
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local reply prompt
  prompt="$(_ "$@")"
  read_input "    $prompt [y/N] " || REPLY=""
  reply="$REPLY"
  [[ "$reply" =~ ^[YyТт]$ ]]
}

usage() {
  if [[ "${GDMOUNT_UI_LANG:-uk}" == en ]]; then
    cat <<'EOF'
gdmount - Google Drive as a local device

Your Google Drive (all of it, or only chosen folders) is downloaded to this computer
and shown as a device named "Google Drive". You work with local files only: it works
offline and there is no size limit except free disk space. Changes can be synced
manually or in the background with a chosen interval.

Usage: gdmount COMMAND [OPTIONS]
Running install.sh without a command starts installation.

Commands:
  install [options]         install, download and mount
  sync                      sync with Google Drive right now
  mode [all|selected]       show or change what is downloaded:
                              all       the whole Google Drive
                              selected  only chosen folders
  local [list|add|remove]   manage chosen folders (mode "selected")
  sync-mode [manual|auto]   choose manual or periodic two-way sync
  status                    mount, pending sync changes and disk-space status
  start                     mount the drive and start background sync
  stop                      unmount the drive and stop background sync
  switch-account            switch Google account
  uninstall [options]       remove files and settings created by the script

Install options:
  --all                  download the whole Google Drive
  --folder PATH          download only this folder (can be repeated)
  --remote NAME          rclone remote name (GDRIVE_REMOTE, default: gdrive)
  --mount PATH           mount directory (GDRIVE_MOUNT, default: ~/Google Drive)
  --sync-mode MODE       manual or auto (default for new installs: manual)
  --sync-interval TIME   auto-sync interval, for example 30m or 2h
  --poll-interval TIME   legacy alias; 0 disables background sync
  --yes, -y              do not ask for confirmation
  -h, --help             show help

Interface language: GDMOUNT_UI_LANG=uk|en
EOF
  else
    cat <<'EOF'
gdmount - Google Drive як локальний пристрій

Ваш Google Drive (весь або лише обрані теки) завантажується на комп'ютер і
показується як пристрій «Google Drive». Ви працюєте лише з локальними файлами:
це працює без інтернету, обмеження обсягу — лише вільне місце на диску. Зміни
можна синхронізувати вручну або у фоні з вибраним інтервалом.

Використання: gdmount КОМАНДА [ОПЦІЇ]
Запуск install.sh без команди одразу починає встановлення.

Команди:
  install [опції]           встановити, завантажити й змонтувати
  sync                      синхронізувати з Google Drive зараз
  mode [all|selected]       показати або змінити, що завантажується:
                              all       увесь Google Drive
                              selected  лише обрані теки
  local [list|add|remove]   керувати обраними теками (режим «selected»)
  sync-mode [manual|auto]   обрати ручну або періодичну двосторонню синхронізацію
  status                    стан монтування, черги синхронізації та місця на диску
  start                     змонтувати диск і запустити фонову синхронізацію
  stop                      розмонтувати диск і зупинити фонову синхронізацію
  switch-account            змінити акаунт Google
  uninstall [опції]         видалити файли й налаштування, створені скриптом

Опції встановлення:
  --all                  завантажити весь Google Drive
  --folder ШЛЯХ          завантажити лише цю теку (можна повторювати)
  --remote ІМ'Я          імʼя rclone remote (GDRIVE_REMOTE, типово: gdrive)
  --mount ШЛЯХ           тека монтування (GDRIVE_MOUNT, типово: ~/Google Drive)
  --sync-mode РЕЖИМ       manual або auto (для нової інсталяції типово: manual)
  --sync-interval ЧАС    інтервал авто-синхронізації, наприклад 30m або 2h
  --poll-interval ЧАС    старий псевдонім; 0 вимикає фонову синхронізацію
  --yes, -y              не питати підтвердження
  -h, --help             показати довідку

Мова інтерфейсу: GDMOUNT_UI_LANG=uk|en
EOF
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# State file: remembers what this script created so uninstall does not affect existing settings
# ---------------------------------------------------------------------------
state_set() {
  mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
  sed -i "/^$1=/d" "$STATE_FILE"
  echo "$1=$2" >> "$STATE_FILE"
}
state_get() {
  [[ -f "$STATE_FILE" ]] || return 1
  grep -m1 "^$1=" "$STATE_FILE" | cut -d= -f2-
}
state_is() { [[ "$(state_get "$1" 2>/dev/null || true)" == "1" ]]; }

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
# Check /proc/mounts instead of mountpoint: on a stale FUSE point
# (Transport endpoint is not connected), mountpoint can falsely report “not mounted”.
is_mounted() {
  local esc="${MNT// /\\040}"
  grep -qsF " $esc " /proc/mounts
}

# The mount point exists but is inaccessible (the mergerfs process stopped)
is_stale() { is_mounted && ! stat "$MNT" >/dev/null 2>&1; }

wait_for_mount() {
  local retries="$1" attempt
  for ((attempt = 0; attempt < retries; attempt++)); do
    if is_mounted && ! is_stale; then return 0; fi
    sleep 1
  done
  is_mounted && ! is_stale
}

have_network() { getent hosts www.googleapis.com >/dev/null 2>&1; }

has_selection() { [[ "$OFFLINE_ALL" == "1" || -n "$OFFLINE_FOLDERS" ]]; }

valid_sync_mode() { [[ "$1" == manual || "$1" == auto ]]; }
valid_interval() { [[ "$1" =~ ^[1-9][0-9]*(s|sec|m|min|h|d)$ ]]; }

resolve_bins() {
  FUSERMOUNT_BIN="$(command -v fusermount3 || command -v fusermount)"
  MERGERFS_BIN="$(command -v mergerfs || printf '%s\n' "$HOME/.local/bin/mergerfs")"
}

# Save settings so gdmount can use them without command-line flags
save_config() {
  local temporary_config
  temporary_config="$(mktemp "$STATE_DIR/config.XXXXXXXX")" || return 1
  {
    echo "# Saved by install. Change with: gdmount mode / gdmount local / gdmount install [options]"
    printf ': ${GDRIVE_REMOTE:=%q}\n'          "$REMOTE"
    printf ': ${GDRIVE_MOUNT:=%q}\n'           "$MNT"
    printf ': ${GDRIVE_SYNC_MODE:=%q}\n'       "$SYNC_MODE"
    printf ': ${GDRIVE_SYNC_INTERVAL:=%q}\n'   "$SYNC_INTERVAL"
    printf ': ${GDRIVE_OFFLINE_DIR:=%q}\n'     "$OFFLINE_DIR"
    printf ': ${GDRIVE_OFFLINE_FOLDERS:=%q}\n' "$OFFLINE_FOLDERS"
    printf ': ${GDRIVE_OFFLINE_ALL:=%q}\n'     "$OFFLINE_ALL"
    printf ': ${GDRIVE_ARCHIVE_ID:=%q}\n'      "$ARCHIVE_ID"
    printf ': ${GDRIVE_UI_LANG:=%q}\n'         "$GDMOUNT_UI_LANG"
    printf ': ${GDRIVE_CONF_VERSION:=4}\n'
  } > "$temporary_config" && mv -f -- "$temporary_config" "$CONF_FILE" || {
    rm -f -- "$temporary_config"
    return 1
  }
}

# Copy the script to ~/.local/bin/gdmount so it can be run as a regular command
install_cli() {
  mkdir -p "$CLI_DIR" "$I18N_DIR"
  if [[ -f "$GDMOUNT_SCRIPT_DIR/i18n.sh" ]]; then
    install -m 644 "$GDMOUNT_SCRIPT_DIR/i18n.sh" "$I18N_PATH"
  fi
  if [[ "$SELF" != "$(readlink -f "$CLI_PATH" 2>/dev/null || true)" ]]; then
    install -m 755 "$SELF" "$CLI_PATH"
  fi
  ok "Команду встановлено: gdmount (%s)" "$CLI_PATH"
  case ":$PATH:" in
    *":$CLI_DIR:"*) ;;
    *) warn "%s немає в PATH. Додайте в ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" "$CLI_DIR" ;;
  esac
}

# Background two-way sync: only when enabled and there is something to sync.
# In manual mode no timer or sync service remains installed, so systemd does
# not wake the machine just to check Google Drive.
update_sync_timer() {
  if [[ "$SYNC_MODE" == auto ]] && has_selection; then
    valid_interval "$SYNC_INTERVAL" || die "Некоректний інтервал синхронізації: %s (приклад: 5m)" "$SYNC_INTERVAL"
    mkdir -p -- "$UNIT_DIR"
    cat > "$SYNC_UNIT_FILE" <<EOF
[Unit]
Description=Sync local Google Drive copies with Google Drive

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${CLI_PATH} sync --background
EOF
    cat > "$SYNC_TIMER_FILE" <<EOF
[Unit]
Description=Periodic two-way sync with Google Drive

[Timer]
OnBootSec=2min
OnUnitActiveSec=${SYNC_INTERVAL}
Unit=${SYNC_SERVICE}

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$SYNC_TIMER"
  else
    stop_sync_units || die "Не вдалося зупинити фонову синхронізацію. Перевірте служби systemd і повторіть."
    if [[ -f "$SYNC_TIMER_FILE" ]]; then systemctl --user disable "$SYNC_TIMER"; fi
    rm -f "$SYNC_UNIT_FILE" "$SYNC_TIMER_FILE"
    systemctl --user daemon-reload
  fi
}

# The device itself: local copies shown as a mount named "Google Drive".
# Works without network. mergerfs with a single branch is a transparent view of the local data.
write_view_unit() {
  resolve_bins
  mkdir -p "$UNIT_DIR"
  cat > "$VIEW_UNIT_FILE" <<EOF
[Unit]
Description=Google Drive (local copies mounted as a device)

[Service]
Type=simple
ExecStart=${MERGERFS_BIN} -f -o "fsname=${MOUNT_NAME},category.create=ff,category.action=ff,category.search=ff,cache.files=off,dropcacheonclose=true" "${OFFLINE_DIR}" "${MNT}"
ExecStop=${FUSERMOUNT_BIN} -u "${MNT}"
ExecStopPost=-${FUSERMOUNT_BIN} -uz "${MNT}"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

# Email of the account linked to the remote (empty if it could not be determined)
current_account() {
  rclone config userinfo "${REMOTE}:" "$@" 2>/dev/null \
    | awk 'tolower($1)=="email:" {print $2; exit}' || true
}

stage_remote_reconnect() {
  local config_path
  config_path="$(rclone config file | tail -n 1)" || return 1
  RCLONE_CONFIG_PATH="$(realpath -e -- "$config_path")" || return 1
  [[ -f "$RCLONE_CONFIG_PATH" ]] || return 1
  STAGED_RCLONE_CONFIG="$(mktemp "$(dirname -- "$RCLONE_CONFIG_PATH")/.gdmount-rclone.XXXXXXXX")" || return 1
  cp -p -- "$RCLONE_CONFIG_PATH" "$STAGED_RCLONE_CONFIG" || return 1
  RCLONE_CONFIG_CHECKSUM="$(sha256sum <"$STAGED_RCLONE_CONFIG")" || return 1
  rclone config reconnect "${REMOTE}:" --config "$STAGED_RCLONE_CONFIG" </dev/tty || return 1
  rclone lsd "${REMOTE}:" --max-depth 1 --config "$STAGED_RCLONE_CONFIG" >/dev/null
}

verify_staged_remote() {
  if [[ "$(sha256sum <"$RCLONE_CONFIG_PATH")" != "$RCLONE_CONFIG_CHECKSUM" ]]; then
    die "Налаштування rclone змінилися під час входу. Повторіть команду."
  fi
}

apply_staged_remote() {
  verify_staged_remote
  mv -f -- "$STAGED_RCLONE_CONFIG" "$RCLONE_CONFIG_PATH"
  STAGED_RCLONE_CONFIG=""
}

has_local_copy() {
  [[ -d "$OFFLINE_DIR" && -n "$(ls -A -- "$OFFLINE_DIR")" ]]
}

archive_account_copy() {
  local archive
  # Invalidate histories before moving files, including if interrupted.
  rm -f -- "$STATE_DIR"/bisync-*
  if has_local_copy; then
    mkdir -p -- "$OFFLINE_ARCHIVE"
    archive="$(mktemp -d "$OFFLINE_ARCHIVE/account-switch-XXXXXXXXXX")"
    mv -- "$OFFLINE_DIR" "$archive/offline"
    info "Копію попереднього акаунта збережено: %s" "$archive/offline"
  fi
  mkdir -p -- "$OFFLINE_DIR"
  ARCHIVE_ID=""
}

reset_account_selection() {
  OFFLINE_ALL=0
  OFFLINE_FOLDERS=""
  PREV_ALL=0
  PREV_FOLDERS=""
  save_config
}

rclone_auth_port_pids() {
  command -v fuser >/dev/null 2>&1 || return 0
  fuser -n tcp "$RCLONE_AUTH_PORT" 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i}'
}

rclone_auth_port_busy() {
  if command -v ss >/dev/null 2>&1; then
    if ss -H -ltn "sport = :$RCLONE_AUTH_PORT" 2>/dev/null | grep -q .; then
      return 0
    fi
  fi
  [[ -n "$(rclone_auth_port_pids)" ]]
}

prepare_rclone_auth_port() {
  rclone_auth_port_busy || return 0

  warn "Порт входу Google (127.0.0.1:%s) уже зайнятий." "$RCLONE_AUTH_PORT"
  local pids pid pid_user pid_comm details current_user
  pids="$(rclone_auth_port_pids)"
  if [[ -z "$pids" ]]; then
    info "Закрийте іншу авторизацію або звільніть порт %s і повторіть команду." "$RCLONE_AUTH_PORT"
    return 1
  fi

  current_user="$(id -un)"
  local -a stale_pids=()
  for pid in $pids; do
    pid_user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')"
    pid_comm="$(ps -o comm= -p "$pid" 2>/dev/null | awk '{$1=$1; print}')"
    details="$(ps -o args= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')"
    info "Порт займає процес %s: %s" "$pid" "${details:-$pid_comm}"
    if [[ "$pid_user" == "$current_user" && "$pid_comm" == rclone ]]; then
      stale_pids+=("$pid")
    fi
  done

  if ((${#stale_pids[@]} && ASSUME_YES == 0)) && has_terminal; then
    if ask "Завершити завислий процес rclone і повторити вхід?"; then
      for pid in "${stale_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
      for _ in 1 2 3 4 5; do
        if ! rclone_auth_port_busy; then
          info "Порт звільнено; повторюю вхід у Google."
          return 0
        fi
        sleep 0.2
      done
      warn "Не вдалося звільнити порт входу Google."
    fi
  fi

  info "Закрийте іншу авторизацію або звільніть порт %s і повторіть команду." "$RCLONE_AUTH_PORT"
  return 1
}

pkg_install() {
  if   command -v dnf    >/dev/null; then sudo dnf install -y "$@"
  elif command -v apt    >/dev/null; then sudo apt install -y "$@"
  elif command -v pacman >/dev/null; then sudo pacman -S --noconfirm "$@"
  elif command -v zypper >/dev/null; then sudo zypper install -y "$@"
  else die "Невідомий пакетний менеджер. Встановіть rclone і fuse3 вручну."
  fi
}

pkg_remove() {
  if   command -v dnf    >/dev/null; then sudo dnf remove -y "$@"
  elif command -v apt    >/dev/null; then sudo apt remove -y "$@"
  elif command -v pacman >/dev/null; then sudo pacman -R --noconfirm "$@"
  elif command -v zypper >/dev/null; then sudo zypper remove -y "$@"
  else warn "Невідомий пакетний менеджер, видаліть пакет %s вручну." "$*"; return 1
  fi
}

do_unmount() {
  local path="${1:-$MNT}"
  grep -qsF " ${path// /\\040} " /proc/mounts || return 0
  if command -v fusermount3 >/dev/null; then
    fusermount3 -u "$path" 2>/dev/null || fusermount3 -uz "$path" || return 1
  elif command -v fusermount >/dev/null; then
    fusermount -u "$path" 2>/dev/null || fusermount -uz "$path" || return 1
  else
    umount "$path" 2>/dev/null || return 1
  fi
}

stop_sync_units() {
  local unit
  for unit in "$SYNC_TIMER" "$SYNC_SERVICE"; do
    if [[ -f "$UNIT_DIR/$unit" ]] || systemctl --user is-active --quiet "$unit" 2>/dev/null; then
      systemctl --user stop "$unit" || return 1
    fi
  done
}

stop_drive() {
  stop_sync_units || return 1
  if [[ -f "$VIEW_UNIT_FILE" ]] || systemctl --user is-active --quiet "$VIEW_SERVICE" 2>/dev/null; then
    systemctl --user stop "$VIEW_SERVICE" || return 1
  fi
  if is_mounted; then do_unmount "$MNT" || return 1; fi
  ! is_mounted
}

remember_running_units() {
  RUNNING_UNITS=()
  local unit
  for unit in "$VIEW_SERVICE" "$SYNC_TIMER"; do
    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then RUNNING_UNITS+=("$unit"); fi
  done
}

restore_running_units() {
  local unit failed=0
  RESTORE_RUNNING_UNITS=0
  for unit in "${RUNNING_UNITS[@]}"; do
    if [[ "$unit" == "$SYNC_TIMER" ]] && ! has_selection; then continue; fi
    if ! systemctl --user start "$unit"; then
      warn "Не вдалося відновити службу %s. Повторіть: gdmount start" "$unit"
      failed=1
    elif [[ "$unit" == "$VIEW_SERVICE" ]] && ! wait_for_mount 15; then
      warn "Монтування не з'явилося. Логи: journalctl --user -u %s -n 50" "$VIEW_SERVICE"
      failed=1
    fi
  done
  return "$failed"
}

validate_mount_target() {
  if is_mounted; then
    if [[ "$MNT" == "$CONFIGURED_MOUNT" ]] &&
       [[ -f "$VIEW_UNIT_FILE" || -f "$UNIT_DIR/$LEGACY_VIEW_SERVICE" || -f "$UNIT_DIR/$LEGACY_RCLONE_SERVICE" ]]; then
      return 0
    fi
    die "Точку монтування %s уже використовує інший пристрій. Оберіть іншу теку (--mount)." "$MNT"
  fi
  if [[ -e "$MNT" && ! -d "$MNT" ]]; then
    die "Точка монтування %s має бути текою. Оберіть інший шлях (--mount)." "$MNT"
  fi
  if [[ -d "$MNT" && -n "$(ls -A -- "$MNT")" ]]; then
    die "%s не порожня. Оберіть іншу теку (--mount) або очистіть цю." "$MNT"
  fi
}

rclone_version_ok() {
  local v
  v="$(rclone version 2>/dev/null | awk 'NR==1 {print $2}')"
  v="${v#v}"; v="${v%%-*}"
  [[ -n "$v" && "$(printf '%s\n%s\n' "$v" "$MIN_RCLONE" | sort -V | head -1)" == "$MIN_RCLONE" ]]
}

# Keep backend NOTICE messages out of the user-facing output; retain errors.
rclone_without_notices() {
  command rclone --log-level ERROR "$@"
}

# Two-way sync needs a recent rclone; distribution packages are often too old
ensure_rclone_version() {
  rclone_version_ok && return 0
  warn "Версія rclone застаріла: для двосторонньої синхронізації потрібна %s або новіша." "$MIN_RCLONE"
  if ask "Встановити актуальний rclone з офіційного сайту rclone.org (потрібен sudo)?"; then
    command -v curl >/dev/null || die "Для завантаження rclone потрібен curl."
    curl -fsSL https://rclone.org/install.sh | sudo bash || true
    hash -r
    rclone_version_ok || die "Не вдалося оновити rclone. Встановіть його вручну: https://rclone.org/install/"
    ok "Встановлено: %s" "$(rclone version | head -1)"
  else
    die "Оновіть rclone вручну: https://rclone.org/install/"
  fi
}
# ---------------------------------------------------------------------------
# mergerfs (used to show the local copies as a mounted device)
# ---------------------------------------------------------------------------
install_mergerfs_static() {
  local machine asset metadata url digest tmpdir archive binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|aarch64) asset="mergerfs-static-linux_${machine}.tar.gz" ;;
    *) die "Для архітектури %s не знайшов офіційний mergerfs static build." "$machine" ;;
  esac
  command -v curl >/dev/null || die "Для завантаження mergerfs потрібен curl."
  command -v python3 >/dev/null || die "Для перевірки релізу mergerfs потрібен python3."
  tmpdir="$(mktemp -d)"
  if ! curl -fsSL "https://api.github.com/repos/trapexit/mergerfs/releases?per_page=100" -o "$tmpdir/releases.json"; then
    rm -rf -- "$tmpdir"
    die "Не вдалося отримати список офіційних релізів mergerfs."
  fi
  if ! metadata="$(python3 -c 'import json,sys; releases=json.load(open(sys.argv[1])); wanted={sys.argv[2], sys.argv[2].replace("_", "-")}; found=next((a for r in releases for a in r.get("assets",[]) if a.get("name") in wanted),None); print((found or {}).get("name", ""), (found or {}).get("browser_download_url", ""), (found or {}).get("digest", "") or "")' "$tmpdir/releases.json" "$asset")"; then
    rm -rf -- "$tmpdir"
    die "Не вдалося прочитати список офіційних файлів mergerfs."
  fi
  read -r asset url digest <<< "$metadata"
  digest="${digest#sha256:}"
  if [[ ! "$url" =~ ^https://github\.com/trapexit/mergerfs/releases/download/ ]]; then
    rm -rf -- "$tmpdir"
    die "У доступних офіційних релізах mergerfs не знайдено static-збірку для %s." "$machine"
  fi
  archive="$tmpdir/$asset"
  if ! curl -fsSL "$url" -o "$archive"; then
    rm -rf -- "$tmpdir"
    die "Не вдалося завантажити офіційний архів mergerfs."
  fi
  if [[ -n "$digest" ]]; then
    if [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ ]] || ! printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - >/dev/null; then
      rm -rf -- "$tmpdir"
      die "SHA-256 офіційного архіву mergerfs не збігається."
    fi
  else
    warn "GitHub не опублікував SHA-256 для цього архіву; використовую HTTPS-завантаження з офіційного релізу."
  fi
  if ! tar -xzf "$archive" -C "$tmpdir"; then
    rm -rf -- "$tmpdir"
    die "Не вдалося розпакувати mergerfs."
  fi
  binary="$(find "$tmpdir" -type f -name mergerfs -print -quit)"
  if [[ -z "$binary" ]]; then
    rm -rf -- "$tmpdir"
    die "В офіційному архіві не знайдено виконуваний файл mergerfs."
  fi
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$binary" "$HOME/.local/bin/mergerfs"
  state_set MERGERFS_STATIC_INSTALLED 1
  rm -rf -- "$tmpdir"
  ok "Встановлено офіційний mergerfs static build у ~/.local/bin/mergerfs"
}

install_mergerfs_fedora_rpm() {
  local machine fedora asset metadata url digest tmpdir package
  machine="$(uname -m)"
  [[ "$machine" == x86_64 || "$machine" == aarch64 ]] || return 1
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == fedora && "${VERSION_ID:-}" =~ ^[0-9]+$ ]] || return 1
  fedora="$VERSION_ID"
  command -v curl >/dev/null && command -v python3 >/dev/null || return 1
  tmpdir="$(mktemp -d)"
  if ! curl -fsSL "https://api.github.com/repos/trapexit/mergerfs/releases?per_page=100" -o "$tmpdir/releases.json"; then
    rm -rf -- "$tmpdir"
    return 1
  fi
  if ! metadata="$(python3 -c 'import json,sys; releases=json.load(open(sys.argv[1])); suffix=".fc"+sys.argv[2]+"."+sys.argv[3]+".rpm"; found=next((a for r in releases for a in r.get("assets",[]) if a.get("name", "").startswith("mergerfs-") and a["name"].endswith(suffix)),None); print((found or {}).get("name", ""), (found or {}).get("browser_download_url", ""), (found or {}).get("digest", "") or "")' "$tmpdir/releases.json" "$fedora" "$machine")"; then
    rm -rf -- "$tmpdir"
    return 1
  fi
  read -r asset url digest <<< "$metadata"
  if [[ -z "$asset" || ! "$url" =~ ^https://github\.com/trapexit/mergerfs/releases/download/ ]]; then
    rm -rf -- "$tmpdir"
    return 1
  fi
  package="$tmpdir/$asset"
  if ! curl -fsSL "$url" -o "$package"; then
    rm -rf -- "$tmpdir"
    return 1
  fi
  digest="${digest#sha256:}"
  if [[ -n "$digest" ]] && { [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ ]] || ! printf '%s  %s\n' "$digest" "$package" | sha256sum -c - >/dev/null; }; then
    rm -rf -- "$tmpdir"
    die "SHA-256 офіційного RPM mergerfs не збігається."
  fi
  info "Встановлюю офіційний RPM mergerfs для Fedora %s..." "$fedora"
  if ! sudo dnf install -y "$package"; then
    rm -rf -- "$tmpdir"
    return 1
  fi
  rm -rf -- "$tmpdir"
  return 0
}

install_mergerfs_fedora45_copr() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == fedora && "${VERSION_ID:-}" == 45 ]] || return 1
  command -v dnf >/dev/null || return 1
  ask "Увімкнути сторонній COPR-репозиторій errornointernet/mergerfs для Fedora 45?" || return 1
  info "Увімкнюю COPR errornointernet/mergerfs для Fedora 45..."
  sudo dnf copr enable -y errornointernet/mergerfs || return 1
  sudo dnf install -y mergerfs
}

ensure_mergerfs() {
  command -v mergerfs >/dev/null && return 0
  [[ -x "$HOME/.local/bin/mergerfs" ]] && return 0
  info "Встановлюю mergerfs із системного репозиторію..."
  if pkg_install mergerfs; then return 0; fi
  if install_mergerfs_fedora_rpm; then return 0; fi
  if install_mergerfs_fedora45_copr; then return 0; fi
  warn "У системному репозиторії пакета немає; завантажую офіційний static build."
  install_mergerfs_static
  [[ -x "$HOME/.local/bin/mergerfs" ]] || die "mergerfs не встановився."
}


# ---------------------------------------------------------------------------
# Folder selection and two-way sync
# ---------------------------------------------------------------------------
validate_offline_folder() {
  local folder="$1"
  [[ -n "$folder" && "$folder" != /* && "$folder" != "." ]] || return 1
  [[ "$folder" != *$'\n'* ]] || return 1
  [[ "/$folder/" != *"/../"* && "/$folder/" != *"/./"* ]] || return 1
}

normalize_offline_folder() {
  local folder="$1"
  while [[ "$folder" == *//* ]]; do folder="${folder//\/\//\/}"; done
  printf '%s' "${folder%/}"
}

# The local data directory and the mount point must not overlap
validate_offline_dir() {
  local offline_abs mount_abs
  offline_abs="$(realpath -m -- "$OFFLINE_DIR")"
  mount_abs="$(realpath -m -- "$MNT")"
  [[ "$offline_abs" != "$mount_abs" && "$offline_abs" != "$mount_abs/"* && "$mount_abs" != "$offline_abs/"* ]]
}

bisync_marker() {
  printf '%s/bisync-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
}

archive_local_path() {
  local source="$1" destination="$OFFLINE_ARCHIVE/$ARCHIVE_ID/$2"
  mkdir -p "$(dirname "$destination")"
  if [[ -e "$destination" || -L "$destination" ]]; then
    mv -- "$destination" "${destination}.$(date +%s%N)"
  fi
  mv -- "$source" "$destination"
}

ensure_selection_archive() {
  [[ -z "$ARCHIVE_ID" ]] || return 0
  local directory
  mkdir -p -- "$OFFLINE_ARCHIVE"
  directory="$(mktemp -d "$OFFLINE_ARCHIVE/selection-XXXXXXXXXX")"
  ARCHIVE_ID="${directory##*/}"
}

# Move local data of folders that are no longer selected into the archive (nothing is deleted)
prune_local_cache_dir() {
  local directory="$1" relative="$2" selected child child_rel
  local has_descendant=0
  while IFS= read -r selected; do
    [[ -n "$selected" ]] || continue
    if [[ "$selected" == "$relative" ]]; then return 0; fi
    [[ "$selected" == "$relative/"* ]] && has_descendant=1
  done <<< "$OFFLINE_FOLDERS"
  if [[ $has_descendant -eq 0 ]]; then
    archive_local_path "$directory" "$relative"
    return 0
  fi
  local -a children=("$directory"/* "$directory"/.[!.]* "$directory"/..?*)
  for child in "${children[@]}"; do
    [[ -e "$child" || -L "$child" ]] || continue
    child_rel="${child#"$OFFLINE_DIR/"}"
    if [[ -d "$child" && ! -L "$child" ]]; then
      prune_local_cache_dir "$child" "$child_rel"
    else
      archive_local_path "$child" "$child_rel"
    fi
  done
}

prune_unselected_local_data() {
  [[ "$OFFLINE_ALL" == "1" ]] && return 0
  [[ -d "$OFFLINE_DIR" ]] || return 0
  local -a children=("$OFFLINE_DIR"/* "$OFFLINE_DIR"/.[!.]* "$OFFLINE_DIR"/..?*)
  local child relative
  for child in "${children[@]}"; do
    [[ -e "$child" || -L "$child" ]] || continue
    relative="${child#"$OFFLINE_DIR/"}"
    if [[ -d "$child" && ! -L "$child" ]]; then
      prune_local_cache_dir "$child" "$relative"
    else
      archive_local_path "$child" "$relative"
    fi
  done
}

add_offline_folder() {
  local folder current
  validate_offline_folder "${1%/}" || die "Некоректний шлях теки на Google Drive: %s" "$1"
  folder="$(normalize_offline_folder "$1")"
  while IFS= read -r current; do
    [[ "$current" == "$folder" ]] && return 0
  done <<< "$OFFLINE_FOLDERS"
  if [[ -n "$OFFLINE_FOLDERS" ]]; then OFFLINE_FOLDERS+=$'\n'; fi
  OFFLINE_FOLDERS+="$folder"
}

has_selected_ancestor() {
  local folder="$1" selected
  while IFS= read -r selected; do
    [[ -n "$selected" && "$folder" == "$selected/"* ]] && return 0
  done <<< "$2"
  return 1
}

selected_targets() {
  if [[ "$1" == 1 ]]; then
    printf '.\n'
    return
  fi
  local folder
  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    has_selected_ancestor "$folder" "$2" || printf '%s\n' "$folder"
  done <<< "$2"
  return 0
}

contains_target() { [[ $'\n'$1$'\n' == *$'\n'"$2"$'\n'* ]]; }

remote_folder_available() {
  rclone_without_notices lsd "${REMOTE}:$1" >/dev/null 2>&1
}

validate_new_folders() {
  local folder
  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    contains_target "$1" "$folder" && continue
    remote_folder_available "$folder" || die "Не вдалося знайти теку %s." "${REMOTE}:$folder"
  done <<< "$OFFLINE_FOLDERS"
}

folder_selection_index() {
  local value="$1" max="$2"
  while [[ "$value" == 0* && ${#value} -gt 1 ]]; do value="${value#0}"; done
  ((${#value} <= ${#max})) || return 1
  REPLY=$((10#$value))
  ((REPLY >= 1 && REPLY <= max))
}

# Interactive choice of top-level folders (numbers and inclusive ranges)
choose_offline_folders() {
  local picker_mode="$1" folder saved marker listing selection index number range_start range_end range_start_raw range_end_raw selection_part valid current
  local -a folders=() selections=() chosen=()
  echo
  info "Доступні теки на Google Drive:"
  listing="$(rclone_without_notices lsf --dirs-only "${REMOTE}:")" || die "Не вдалося отримати список тек Google Drive."
  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    folders+=("${folder%/}")
  done <<< "$listing"
  while IFS= read -r saved; do
    [[ -n "$saved" ]] || continue
    current=0
    for folder in "${folders[@]}"; do
      if [[ "$folder" == "$saved" ]]; then current=1; break; fi
    done
    [[ $current -eq 1 ]] || folders+=("$saved")
  done <<< "$OFFLINE_FOLDERS"

  for index in "${!folders[@]}"; do
    marker=""
    while IFS= read -r saved; do
      if [[ "$saved" == "${folders[index]}" ]]; then
        marker=" [$(_ "вибрано")]"
        break
      fi
    done <<< "$OFFLINE_FOLDERS"
    printf '  %d) %s%s\n' "$((index + 1))" "${folders[index]}" "$marker"
  done
  if [[ "$picker_mode" == add ]]; then
    info "Введіть номери тек для додавання через кому (наприклад 1-3,5). Enter скасовує додавання."
  else
    info "Введіть повний список номерів через кому (наприклад 1-3,5). Enter зберігає поточний вибір, 0 очищає список."
  fi
  while true; do
    read_input "$(_ "Номери тек: ")" || return 1
    selection="${REPLY//[[:space:]]/}"
    [[ -n "$selection" ]] || return 0
    if [[ "$selection" == "0" ]]; then
      [[ "$picker_mode" == add ]] && return 0
      OFFLINE_FOLDERS=""
      return 0
    fi
    if [[ "$selection" == ,* || "$selection" == *, || "$selection" == *,,* ]]; then
      warn "Некоректний вибір; введіть номери або діапазони через кому, наприклад 1-3,5."
      continue
    fi
    IFS=, read -r -a selections <<< "$selection"
    chosen=()
    valid=1
    for selection_part in "${selections[@]}"; do
      if [[ "$selection_part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        range_start_raw="${BASH_REMATCH[1]}"
        range_end_raw="${BASH_REMATCH[2]}"
        if ! folder_selection_index "$range_start_raw" "${#folders[@]}"; then valid=0; break; fi
        range_start=$REPLY
        if ! folder_selection_index "$range_end_raw" "${#folders[@]}"; then valid=0; break; fi
        range_end=$REPLY
        if ((range_start > range_end)); then valid=0; break; fi
        for ((number = range_start; number <= range_end; number++)); do
          folder="${folders[number - 1]}"
          current=0
          for saved in "${chosen[@]}"; do
            [[ "$saved" == "$folder" ]] && current=1
          done
          [[ $current -eq 1 ]] || chosen+=("$folder")
        done
      elif [[ "$selection_part" =~ ^[0-9]+$ ]]; then
        if ! folder_selection_index "$selection_part" "${#folders[@]}"; then valid=0; break; fi
        number=$REPLY
        folder="${folders[number - 1]}"
        current=0
        for saved in "${chosen[@]}"; do
          [[ "$saved" == "$folder" ]] && current=1
        done
        [[ $current -eq 1 ]] || chosen+=("$folder")
      else
        valid=0
        break
      fi
    done
    if [[ $valid -eq 0 ]]; then
      warn "Некоректний вибір; введіть номери або діапазони через кому, наприклад 1-3,5."
      continue
    fi
    [[ "$picker_mode" == add ]] || OFFLINE_FOLDERS=""
    for folder in "${chosen[@]}"; do
      add_offline_folder "$folder"
    done
    return 0
  done
}

# Ask what to download: the whole drive or chosen folders
choose_scope() {
  if (( SCOPE_ALL_FLAG )) || (( ${#SCOPE_FOLDER_FLAGS[@]} )); then return 0; fi
  if [[ $ASSUME_YES -eq 1 ]] || ! has_terminal; then
    has_selection && return 0
    die "Вкажіть, що завантажувати: --all (весь диск) або --folder ШЛЯХ (можна кілька разів)."
  fi
  local default=1 choice
  [[ "$OFFLINE_ALL" != "1" && -n "$OFFLINE_FOLDERS" ]] && default=2
  while true; do
    echo
    info "Що завантажити на цей комп'ютер?"
    info "1) Увесь Google Drive"
    info "2) Лише вибрані теки"
    read_input "$(_ "Режим [1=весь диск, 2=вибрані теки, Enter=%s]: " "$default")" || die "Вибір тек перервано."
    choice="${REPLY,,}"
    [[ -n "$choice" ]] || choice="$default"
    case "$choice" in
      1|all|a)
        OFFLINE_ALL=1; OFFLINE_FOLDERS=""
        return 0
        ;;
      2|selected|s)
        [[ "$OFFLINE_ALL" != "1" ]] || OFFLINE_FOLDERS=""
        OFFLINE_ALL=0
        choose_offline_folders replace || die "Вибір тек перервано."
        if [[ -z "$OFFLINE_FOLDERS" ]]; then
          warn "Не вибрано жодної теки."
          continue
        fi
        return 0
        ;;
      *) warn "Виберіть 1 або 2." ;;
    esac
  done
}

# Sync one target: "." is the whole drive, anything else is a folder path
sync_one_target() {
  local folder="$1" remote_path local_path marker label
  local -a progress=()
  [[ -t 1 ]] && progress=(--progress)
  if [[ "$folder" == "." ]]; then
    remote_path="${REMOTE}:"; local_path="$OFFLINE_DIR"; label="Google Drive"
  else
    validate_offline_folder "$folder" || { err "Некоректний шлях теки: %s" "$folder"; return 1; }
    remote_path="${REMOTE}:${folder}"; local_path="$OFFLINE_DIR/$folder"; label="$folder"
    if ! remote_folder_available "$folder"; then
      err "Не вдалося знайти теку %s." "$remote_path"
      return 1
    fi
  fi
  mkdir -p "$local_path"
  marker="$(bisync_marker "$remote_path")"
  if [[ -f "$marker" ]]; then
    info "Синхронізую: %s" "$label"
    rclone_without_notices bisync "$remote_path" "$local_path" "${progress[@]}" \
      --create-empty-src-dirs --conflict-resolve newer --conflict-loser num \
      || { err "Не вдалося синхронізувати %s. Перевірте стан і повторіть: gdmount sync" "$remote_path"; return 1; }
    return 0
  fi
  if [[ -z "$(ls -A "$local_path" 2>/dev/null)" ]]; then
    info "Завантажую %s на цей комп'ютер..." "$label"
    rclone_without_notices copy --create-empty-src-dirs "${progress[@]}" "$remote_path" "$local_path" \
      || { err "Не вдалося завантажити %s." "$remote_path"; return 1; }
  fi
  info "Узгоджую локальну копію з Google Drive: %s" "$label"
  mkdir -p "$OFFLINE_ARCHIVE"
  rclone_without_notices bisync "$remote_path" "$local_path" "${progress[@]}" \
    --create-empty-src-dirs --resync --resync-mode newer --conflict-resolve newer --conflict-loser num \
    --backup-dir2 "$OFFLINE_ARCHIVE/initial-sync-$(date +%s%N)" \
    || { err "Не вдалося початково узгодити %s." "$remote_path"; return 1; }
  mkdir -p "$STATE_DIR"
  : > "$marker"
}

sync_offline_folders() {
  if ! has_selection; then
    info "Нічого синхронізувати: не вибрано ні всього диска, ні тек. Дивіться: gdmount mode"
    return 0
  fi
  command -v rclone >/dev/null || { err "rclone не встановлено."; return 1; }
  validate_offline_dir || { err "Тека локальних даних має бути окремо від теки монтування."; return 1; }
  mkdir -p "$OFFLINE_DIR"
  local folder
  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    sync_one_target "$folder" || return 1
  done < <(selected_targets "$OFFLINE_ALL" "$OFFLINE_FOLDERS")
}

# Changes to the selection must never turn an archive move into a deletion
# on a target that is still active. Only outermost folders own a bisync history.
apply_scope_change() {
  local old_all="$1" old_folders="$2" operation="$3"
  local old_targets targets folder remote_path archived interrupted_archive
  old_targets="$(selected_targets "$old_all" "$old_folders")"
  targets="$(selected_targets "$OFFLINE_ALL" "$OFFLINE_FOLDERS")"
  validate_offline_dir || die "Тека локальних даних має бути окремо від теки монтування."

  if [[ "$operation" == add ]]; then validate_new_folders "$old_folders"; fi

  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    contains_target "$targets" "$folder" && continue
    if have_network && { [[ "$folder" == "." ]] || remote_folder_available "$folder"; }; then
      sync_one_target "$folder" || die "Не вдалося завершити синхронізацію перед зміною вибору."
    else
      remote_path="${REMOTE}:"
      if [[ "$folder" != "." ]]; then remote_path+="$folder"; fi
      warn "Не вдалося підключитися до %s. Локальні зміни буде збережено в архіві." "$remote_path"
    fi
  done <<< "$old_targets"

  while IFS= read -r folder; do
    [[ -n "$folder" ]] || continue
    if contains_target "$old_targets" "$folder"; then
      [[ "$operation" == install ]] || continue
    else
      remote_path="${REMOTE}:"
      if [[ "$folder" != "." ]]; then remote_path+="$folder"; fi
      rm -f -- "$(bisync_marker "$remote_path")"
    fi
    [[ "$operation" != remove ]] || continue
    if [[ "$folder" != "." && -n "$ARCHIVE_ID" ]]; then
      archived="$OFFLINE_ARCHIVE/$ARCHIVE_ID/$folder"
      if [[ ! -e "$OFFLINE_DIR/$folder" && -d "$archived" ]]; then
        mkdir -p -- "$(dirname "$OFFLINE_DIR/$folder")"
        # Keep the archived copy intact until the initial download succeeds.
        cp -a -- "$archived" "$OFFLINE_DIR/$folder"
      fi
    fi
    if ! sync_one_target "$folder"; then
      if [[ "$operation" == add && "$old_all" != 1 ]]; then
        # Preserve incomplete downloads while restoring the previous local view.
        OFFLINE_ALL="$old_all"
        OFFLINE_FOLDERS="$old_folders"
        mkdir -p -- "$OFFLINE_ARCHIVE"
        interrupted_archive="$(mktemp -d "$OFFLINE_ARCHIVE/interrupted-selection-XXXXXXXXXX")"
        ARCHIVE_ID="${interrupted_archive##*/}"
        prune_unselected_local_data
        warn "Дані незавершеного завантаження збережено в %s." "$interrupted_archive"
      fi
      die "Не вдалося завантажити дані для нового вибору. Перевірте помилку й повторіть команду."
    fi
  done <<< "$targets"

  if [[ "$OFFLINE_ALL" != 1 ]]; then ensure_selection_archive; fi
  save_config
  prune_unselected_local_data
}

# ---------------------------------------------------------------------------
# Migration from the old scheme (network drive through rclone mount)
# ---------------------------------------------------------------------------
legacy_queue_count() {
  local user pass out
  [[ -f "$LEGACY_RC_ENV" ]] || { echo 0; return 0; }
  user="$(grep -m1 '^RCLONE_RC_USER=' "$LEGACY_RC_ENV" | cut -d= -f2-)"
  pass="$(grep -m1 '^RCLONE_RC_PASS=' "$LEGACY_RC_ENV" | cut -d= -f2-)"
  if out="$(rclone rc --url "http://${LEGACY_RC_ADDR}" --user "$user" --pass "$pass" vfs/queue 2>/dev/null)"; then
    grep -cE '"name":' <<<"$out" || true
  else
    echo 0
  fi
}

legacy_dirty_count() {
  [[ -d "$LEGACY_CACHE_DIR/vfsMeta" ]] || { echo 0; return 0; }
  grep -rlE '"Dirty":[[:space:]]*true' "$LEGACY_CACHE_DIR/vfsMeta" 2>/dev/null | wc -l || true
}

migrate_legacy() {
  local found=0 unit n waited=0
  for unit in "$LEGACY_RCLONE_SERVICE" "$LEGACY_WATCH_SERVICE" "$LEGACY_VIEW_SERVICE"; do
    [[ -f "$UNIT_DIR/$unit" ]] && found=1
  done
  (( found )) || return 0

  step "Перехід зі старої схеми (мережевий диск) на локальні копії"
  info "Мережевий диск більше не використовується: працюватимете лише з локальними файлами."
  systemctl --user disable --now "$LEGACY_WATCH_SERVICE" >/dev/null 2>&1 || true
  systemctl --user disable --now gdmount-sync.timer >/dev/null 2>&1 || true
  systemctl --user disable --now "$LEGACY_VIEW_SERVICE" >/dev/null 2>&1 || true

  # Files written through the old mount may still be waiting to be uploaded
  if command -v rclone >/dev/null && systemctl --user is-active --quiet "$LEGACY_RCLONE_SERVICE" 2>/dev/null; then
    n="$(legacy_queue_count)"
    if [[ "${n:-0}" -gt 0 ]] && have_network; then
      info "Чекаю, поки вивантажаться файли зі старого кешу (%s), до 180 с..." "$n"
      while (( waited < 180 )); do
        sleep 5; waited=$((waited + 5))
        n="$(legacy_queue_count)"
        [[ "${n:-0}" -eq 0 ]] && break
      done
    fi
  fi
  systemctl --user disable --now "$LEGACY_RCLONE_SERVICE" >/dev/null 2>&1 || true
  do_unmount "$MNT" || true
  do_unmount "$LEGACY_REMOTE_MNT" || true
  rm -f "$UNIT_DIR/$LEGACY_RCLONE_SERVICE" "$UNIT_DIR/$LEGACY_WATCH_SERVICE" \
        "$UNIT_DIR/$LEGACY_VIEW_SERVICE" "$LEGACY_WATCH_SCRIPT" "$LEGACY_RC_ENV"
  systemctl --user daemon-reload
  rmdir "$LEGACY_REMOTE_MNT" 2>/dev/null || true

  n="$(legacy_dirty_count)"
  if [[ "${n:-0}" -gt 0 ]]; then
    warn "У старому кеші %s файл(ів) не вивантажено на Google Drive. Кеш збережено: %s" "$n" "$LEGACY_CACHE_DIR/vfs/"
    warn "Скопіюйте звідти потрібні файли вручну, перш ніж видаляти цю теку."
  elif [[ -d "$LEGACY_CACHE_DIR" ]]; then
    rm -rf "$LEGACY_CACHE_DIR"
    ok "Старий кеш видалено."
  fi

  # The old default mount name was ~/GoogleDrive; the device is now called "Google Drive"
  if [[ $MNT_FROM_FLAG -eq 0 && "$MNT" == "$HOME/GoogleDrive" ]]; then
    rmdir "$MNT" 2>/dev/null || true
    MNT="$HOME/Google Drive"
    info "Тека монтування тепер: %s" "$MNT"
  fi
  ok "Стару схему вимкнено."
}

# ---------------------------------------------------------------------------
# local: chosen folders
# ---------------------------------------------------------------------------
cmd_offline() {
  local folder remaining="" found=0
  case "$OFFLINE_ACTION" in
    ""|list)
      [[ -z "$OFFLINE_PATH" ]] || die "Зайвий аргумент: %s" "$OFFLINE_PATH"
      ;;
    add) ;;
    remove)
      [[ -n "$OFFLINE_PATH" ]] || die "Використання: gdmount local [list|add [ШЛЯХ]|remove ШЛЯХ]"
      ;;
    *) die "Використання: gdmount local [list|add [ШЛЯХ]|remove ШЛЯХ]" ;;
  esac
  case "$OFFLINE_ACTION" in
    ""|list)
      if [[ "$OFFLINE_ALL" == "1" ]]; then
        info "Завантажено весь Google Drive. Щоб обрати окремі теки: gdmount mode selected"
      elif [[ -z "$OFFLINE_FOLDERS" ]]; then
        info "Теки не вибрано. Додати: gdmount local add"
      else
        printf '%s\n' "$OFFLINE_FOLDERS"
      fi
      ;;
    add)
      [[ "$OFFLINE_ALL" != 1 ]] || die "Завантажено весь Google Drive. Щоб обрати окремі теки: gdmount mode selected"
      [[ -n "$OFFLINE_PATH" ]] || has_terminal || die "Без термінала вкажіть шлях: gdmount local add ШЛЯХ"
      command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: gdmount install"
      have_network || die "Немає мережі. Теку не додано: її спершу потрібно завантажити."
      if [[ -n "$OFFLINE_PATH" ]]; then
        add_offline_folder "$OFFLINE_PATH"
      else
        choose_offline_folders add || die "Вибір тек перервано."
      fi
      if [[ "$PREV_FOLDERS" == "$OFFLINE_FOLDERS" ]]; then info "Вибір тек не змінився."; return 0; fi
      apply_scope_change "$PREV_ALL" "$PREV_FOLDERS" add
      update_sync_timer
      ok "Готово."
      ;;
    remove)
      validate_offline_folder "${OFFLINE_PATH%/}" || die "Некоректний шлях теки на Google Drive: %s" "$OFFLINE_PATH"
      OFFLINE_PATH="$(normalize_offline_folder "$OFFLINE_PATH")"
      [[ "$OFFLINE_ALL" != "1" ]] || die "Завантажено весь Google Drive. Щоб обрати окремі теки: gdmount mode selected"
      while IFS= read -r folder; do
        [[ -n "$folder" ]] || continue
        if [[ "$folder" == "$OFFLINE_PATH" ]]; then found=1; continue; fi
        [[ -n "$remaining" ]] && remaining+=$'\n'
        remaining+="$folder"
      done <<< "$OFFLINE_FOLDERS"
      [[ $found -eq 1 ]] || die "Теку не знайдено серед вибраних: %s" "$OFFLINE_PATH"
      OFFLINE_FOLDERS="$remaining"
      apply_scope_change "$PREV_ALL" "$PREV_FOLDERS" remove
      update_sync_timer
      if has_selected_ancestor "$OFFLINE_PATH" "$OFFLINE_FOLDERS"; then
        ok "Окремий вибір для «%s» прибрано. Тека залишається доступною в межах вибраної батьківської теки." "$OFFLINE_PATH"
      else
        ok "Вибір оновлено. Вилучені з пристрою локальні дані збережено в архіві: %s" "$OFFLINE_ARCHIVE"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------
cmd_sync() {
  command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: gdmount install"
  if ! have_network; then
    # The background timer must not fail just because the computer is offline
    [[ $BACKGROUND -eq 1 ]] && exit 0
    die "Немає мережі. Локальні зміни збережено; повторіть gdmount sync, коли зв'язок з'явиться."
  fi
  echo "${C_BOLD}$(_ "Синхронізація з Google Drive")${C_RESET}"
  sync_offline_folders || die "Не вдалося завершити синхронізацію. Перевірте помилку вище й повторіть gdmount sync."
  ok "Синхронізацію завершено."
}

# ---------------------------------------------------------------------------
# mode: what is downloaded
# ---------------------------------------------------------------------------
cmd_mode() {
  # Keep the old `gdmount mode manual|auto` spelling working. The current
  # `mode` command still owns the downloaded-scope values all|selected.
  if [[ "$MODE_ARG" == manual || "$MODE_ARG" == auto ]]; then
    SYNC_MODE_ARG="$MODE_ARG"
    cmd_sync_mode
    return
  fi
  if [[ -z "$MODE_ARG" ]]; then
    if [[ "$OFFLINE_ALL" == "1" ]]; then
      info "Локальна копія: увесь Google Drive"
    else
      info "Локально зберігаються лише вибрані теки:"
      if [[ -n "$OFFLINE_FOLDERS" ]]; then printf '  %s\n' "${OFFLINE_FOLDERS//$'\n'/$'\n'  }"; else info "Теки не вибрано. Додати: gdmount local add"; fi
    fi
    info "Змінити: gdmount mode all | gdmount mode selected"
    return 0
  fi
  case "$MODE_ARG" in
    all)
      command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: gdmount install"
      if [[ "$OFFLINE_ALL" == "1" ]]; then info "Уже завантажується весь диск, нічого змінювати."; return 0; fi
      have_network || die "Для завантаження всього диска потрібна мережа."
      info "Буде завантажено весь Google Drive. Обмежень обсягу немає, потрібне лише вільне місце на диску."
      ask "Продовжити?" || { info "Скасовано."; exit 0; }
      OFFLINE_ALL=1; OFFLINE_FOLDERS=""
      apply_scope_change "$PREV_ALL" "$PREV_FOLDERS" add
      update_sync_timer
      ok "Готово."
      ;;
    selected)
      has_terminal || die "Для вибору тек потрібен термінал. Окрему теку можна додати командою gdmount local add ШЛЯХ."
      command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: gdmount install"
      have_network || die "Для вибору тек потрібен доступ до Google Drive."
      OFFLINE_ALL=0
      choose_offline_folders replace || die "Вибір тек перервано."
      if [[ "$PREV_ALL" == 1 && -z "$OFFLINE_FOLDERS" ]] ||
         [[ "$PREV_ALL" == 0 && "$PREV_FOLDERS" == "$OFFLINE_FOLDERS" ]]; then
        info "Вибір тек не змінився."
        return 0
      fi
      apply_scope_change "$PREV_ALL" "$PREV_FOLDERS" add
      update_sync_timer
      ok "Готово."
      ;;
    *) die "Невідомий режим «%s». Доступні: all, selected" "$MODE_ARG" ;;
  esac
}

cmd_sync_mode() {
  if [[ -z "$SYNC_MODE_ARG" && $SYNC_MODE_FROM_FLAG -eq 0 &&
        $SYNC_INTERVAL_FROM_FLAG -eq 0 ]]; then
    info "Спосіб синхронізації: %s" "$(sync_settings_text)"
    info "Змінити: gdmount sync-mode manual | gdmount sync-mode auto --sync-interval 30m"
    return 0
  fi
  [[ -f "$VIEW_UNIT_FILE" ]] || die "gdmount не встановлено. Виконайте: gdmount install"
  if [[ -n "$SYNC_MODE_ARG" ]]; then SYNC_MODE="$SYNC_MODE_ARG"; fi
  valid_sync_mode "$SYNC_MODE" || die "Невідомий спосіб синхронізації: %s. Доступні: manual, auto" "$SYNC_MODE"
  valid_interval "$SYNC_INTERVAL" || die "Некоректний інтервал синхронізації: %s (приклад: 5m)" "$SYNC_INTERVAL"
  save_config
  update_sync_timer
  info "Спосіб синхронізації: %s" "$(sync_settings_text)"
  if [[ "$SYNC_MODE" == manual ]]; then
    ok "Фонову синхронізацію вимкнено. Запускайте її командою: gdmount sync"
  elif has_selection; then
    ok "Фонову синхронізацію увімкнено. Інтервал: %s" "$SYNC_INTERVAL"
  else
    info "Автоматичний режим збережено; timer запрацює після вибору локальних тек."
  fi
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
install_language_question() {
  [[ $ASSUME_YES -eq 0 ]] && has_terminal || return 0
  [[ $GDMOUNT_LANG_EXPLICIT -eq 0 ]] || return 0
  local reply
  read_input "$(_ "Мова інтерфейсу [uk/en, Enter=%s]: " "$GDMOUNT_UI_LANG")" || die "Встановлення перервано."
  reply="$REPLY"
  case "${reply,,}" in
    uk|1) GDMOUNT_UI_LANG=uk ;;
    en|2) GDMOUNT_UI_LANG=en ;;
    "") ;;
    *) warn "Невідома мова; залишаю %s." "$GDMOUNT_UI_LANG" ;;
  esac
}

install_sync_settings() {
  [[ $ASSUME_YES -eq 0 ]] && has_terminal || return 0
  [[ $SYNC_SETTINGS_CONFIGURED -eq 0 && $SYNC_MODE_FROM_FLAG -eq 0 &&
     $SYNC_INTERVAL_FROM_FLAG -eq 0 ]] || return 0

  local default="$SYNC_MODE" default_label choice interval
  if [[ "$default" == auto ]]; then default_label="$(_ "автоматично")"
  else default_label="$(_ "вручну")"; fi
  while true; do
    echo
    info "Синхронізувати зміни між Google Drive і комп’ютером:"
    info "1) Вручну — gdmount sync"
    info "2) Автоматично — у фоновому режимі"
    read_input "$(_ "Синхронізація [1=вручну, 2=автоматично, Enter=%s]: " "$default_label")" || die "Встановлення перервано."
    choice="${REPLY,,}"
    [[ -n "$choice" ]] || choice="$default"
    case "$choice" in
      1|manual|m)
        SYNC_MODE=manual
        return 0
        ;;
      2|auto|a)
        SYNC_MODE=auto
        while true; do
          read_input "$(_ "Інтервал (наприклад 30m, Enter=%s): " "$SYNC_INTERVAL")" || die "Встановлення перервано."
          interval="$REPLY"
          [[ -n "$interval" ]] || interval="$SYNC_INTERVAL"
          if valid_interval "$interval"; then
            SYNC_INTERVAL="$interval"
            return 0
          fi
          warn "Некоректний інтервал синхронізації: %s (приклад: 5m)" "$interval"
        done
        ;;
      *) warn "Виберіть 1 або 2." ;;
    esac
  done
}

sync_settings_text() {
  if [[ "$SYNC_MODE" == manual ]]; then
    _ "вручну"
  else
    _ "автоматично, кожні %s" "$SYNC_INTERVAL"
  fi
}

scope_text() {
  if [[ "$OFFLINE_ALL" == "1" ]]; then _ "увесь Google Drive"
  elif [[ -n "$OFFLINE_FOLDERS" ]]; then printf '%s' "${OFFLINE_FOLDERS//$'\n'/, }"
  else _ "не вибрано"; fi
}

cmd_install() {
  [[ $EUID -ne 0 ]] || die "Не запускайте від root: сервіс має працювати від вашого користувача."
  echo "${C_BOLD}$(_ "Встановлення gdmount")${C_RESET}"
  info "gdmount завантажить вибрані дані на комп’ютер для доступу офлайн."
  install_language_question
  install_sync_settings
  valid_sync_mode "$SYNC_MODE" || die "Невідомий спосіб синхронізації: %s. Доступні: manual, auto" "$SYNC_MODE"
  valid_interval "$SYNC_INTERVAL" || die "Некоректний інтервал синхронізації: %s (приклад: 5m)" "$SYNC_INTERVAL"
  validate_mount_target
  validate_offline_dir || die "Тека локальних даних має бути окремо від теки монтування."
  if [[ $ASSUME_YES -eq 1 ]] || ! has_terminal; then
    has_selection || die "Вкажіть, що завантажувати: --all (весь диск) або --folder ШЛЯХ (можна кілька разів)."
  fi
  systemctl --user show-environment >/dev/null || die "Керування службами користувача systemd недоступне."
  have_network || die "Немає з'єднання з інтернетом. Підключіться до мережі й повторіть."

  if [[ -n "$LEGACY_OFFLINE_DIR" && -d "$LEGACY_OFFLINE_DIR" ]]; then
    local legacy_abs legacy_mount
    legacy_abs="$(realpath -m -- "$LEGACY_OFFLINE_DIR")"
    legacy_mount="$(realpath -m -- "$MNT")"
    [[ "$legacy_abs" != "$legacy_mount" && "$legacy_abs" != "$legacy_mount/"* && "$legacy_mount" != "$legacy_abs/"* ]] \
      || die "Стара тека локальних копій перетинається з монтуванням; перемістіть її вручну, щоб зберегти дані."
    mkdir -p "$(dirname "$OFFLINE_DIR")"
    if [[ ! -e "$OFFLINE_DIR" ]]; then
      mv -- "$LEGACY_OFFLINE_DIR" "$OFFLINE_DIR"
      ok "Локальні дані перенесено в службове сховище gdmount."
    else
      mkdir -p "$OFFLINE_DIR" "$OFFLINE_ARCHIVE"
      cp -an -- "$LEGACY_OFFLINE_DIR/." "$OFFLINE_DIR/"
      mv -- "$LEGACY_OFFLINE_DIR" "$OFFLINE_ARCHIVE/previous-offline-folder"
      ok "Локальні дані об'єднано; попередню теку збережено в архіві gdmount."
    fi
  fi

  migrate_legacy

  info "Тека Google Drive: %s" "$MNT"
  info "Синхронізація: %s" "$(sync_settings_text)"

  step "1/4 Перевірка rclone, mergerfs та FUSE"
  if command -v rclone >/dev/null; then
    ok "rclone вже встановлено: %s" "$(rclone version | head -1)"
  else
    info "Встановлюю rclone і fuse3 (потрібен sudo)..."
    pkg_install rclone fuse3
    state_set PKG_INSTALLED 1
    ok "Встановлено: %s" "$(rclone version | head -1)"
  fi
  ensure_rclone_version
  ensure_mergerfs
  command -v fusermount3 >/dev/null || command -v fusermount >/dev/null \
    || die "fusermount не знайдено. Встановіть пакет fuse3."
  resolve_bins

  step "2/4 Remote «%s» для Google Drive" "$REMOTE"
  if rclone listremotes | grep -Fx "${REMOTE}:" >/dev/null; then
    ok "Remote вже існує, авторизацію пропускаю."
  else
    info "Зараз відкриється браузер для входу в Google-акаунт."
    has_terminal || die "Для входу в Google потрібен термінал. Налаштуйте remote «%s» через rclone config і повторіть встановлення." "$REMOTE"
    info "(Без графічної сесії: виконайте 'rclone authorize drive' на іншій машині.)"
    prepare_rclone_auth_port || die "Порт входу Google зайнятий. Звільніть порт %s і повторіть: gdmount install" "$RCLONE_AUTH_PORT"
    rclone config create "$REMOTE" drive scope=drive </dev/tty
    state_set REMOTE_CREATED 1
    state_set REMOTE_CREATED_NAME "$REMOTE"
    ok "Remote створено."
  fi
  info "Перевіряю доступ до диска..."
  if rclone lsd "${REMOTE}:" --max-depth 1 >/dev/null 2>&1; then
    ok "Доступ до Google Drive є."
  else
    warn "Remote «%s» існує, але доступ до Google Drive не працює." "$REMOTE"
    if ask "Повторити вхід у Google зараз?"; then
      has_terminal || die "Для входу в Google потрібен термінал. Налаштуйте remote «%s» через rclone config і повторіть встановлення." "$REMOTE"
      info "Зараз відкриється браузер для повторної авторизації."
      prepare_rclone_auth_port || die "Порт входу Google зайнятий. Звільніть порт %s і повторіть: gdmount install" "$RCLONE_AUTH_PORT"
      local old_account new_account requested_all="$OFFLINE_ALL" requested_folders="$OFFLINE_FOLDERS"
      old_account="$(current_account)"
      stage_remote_reconnect || die "Не вдалося оновити доступ до %s. Повторіть: gdmount install" "$REMOTE"
      new_account="$(current_account --config "$STAGED_RCLONE_CONFIG")"
      verify_staged_remote
      if [[ "$REMOTE" == "$CONFIGURED_REMOTE" && ( -z "$old_account" || "$old_account" != "$new_account" ) ]]; then
        # A reconnect with an expired token cannot establish the old identity.
        # Isolate its files before making the newly authorized token active.
        stop_drive || die "Не вдалося зупинити Google Drive. Перевірте служби systemd і повторіть."
        archive_account_copy
        reset_account_selection
        update_sync_timer
        if ((SCOPE_ALL_FLAG || ${#SCOPE_FOLDER_FLAGS[@]})); then
          OFFLINE_ALL="$requested_all"
          OFFLINE_FOLDERS="$requested_folders"
        fi
      fi
      apply_staged_remote
      ok "Авторизацію оновлено; доступ до Google Drive є."
    else
      die "Не вдалося отримати доступ до %s:. Повторіть вхід через: gdmount install" "$REMOTE"
    fi
  fi

  step "3/4 Завантаження на цей комп'ютер"
  choose_scope
  validate_new_folders ""
  if [[ "$REMOTE" != "$CONFIGURED_REMOTE" ]] && { [[ -n "$CONFIGURED_REMOTE" ]] || has_local_copy; }; then
    local new_all="$OFFLINE_ALL" new_folders="$OFFLINE_FOLDERS"
    stop_drive || die "Не вдалося зупинити Google Drive. Перевірте служби systemd і повторіть."
    archive_account_copy
    reset_account_selection
    update_sync_timer
    OFFLINE_ALL="$new_all"
    OFFLINE_FOLDERS="$new_folders"
  fi
  info "Що завантажується: %s" "$(scope_text)"
  info "Обмежень обсягу немає: потрібне лише вільне місце на диску."
  mkdir -p "$OFFLINE_DIR"
  apply_scope_change "$PREV_ALL" "$PREV_FOLDERS" install

  step "4/4 Монтування пристрою «%s»" "$MOUNT_NAME"
  if [[ -f "$VIEW_UNIT_FILE" ]]; then systemctl --user stop "$VIEW_SERVICE"; fi
  if is_mounted; then
    do_unmount "$MNT" || die "Не вдалося зупинити попереднє монтування. Закрийте відкриті файли й повторіть."
  fi
  if is_mounted; then die "Не вдалося розмонтувати %s. Закрийте програми, що використовують диск, і повторіть." "$MNT"; fi
  validate_mount_target
  if [[ -d "$MNT" ]]; then
    ok "Тека існує і порожня: %s" "$MNT"
  else
    mkdir -p "$MNT"
    state_set MNT_CREATED 1
    ok "Створено %s" "$MNT"
  fi
  write_view_unit
  systemctl --user daemon-reload
  systemctl --user enable --now "$VIEW_SERVICE" >/dev/null 2>&1 || true
  if ! wait_for_mount 30; then
    warn "Монтування не з'явилося; автоматично перезапускаю службу й повторюю перевірку."
    if ! systemctl --user restart "$VIEW_SERVICE" || ! wait_for_mount 30; then
      err "Монтування не з'явилося після автоматичного повторного запуску. Подивіться логи:"
      die "  journalctl --user -u %s -n 50" "$VIEW_SERVICE"
    fi
  fi
  ok "Google Drive змонтовано як пристрій «%s»: %s" "$MOUNT_NAME" "$MNT"
  step "Команда gdmount"
  install_cli
  update_sync_timer

  echo
  echo "${C_BOLD}$(_ "Готово.")${C_RESET} $(_ "Google Drive доступний офлайн у теці: %s" "$MNT")"
  info "Завантажено: %s" "$(scope_text)"
  info "Синхронізація: %s" "$(sync_settings_text)"
  info "Команда синхронізації: gdmount sync"
  info "Google Docs/Sheets/Slides завантажуються в експортованому форматі rclone."
  echo
  if [[ "${GDMOUNT_UI_LANG:-uk}" == en ]]; then
    cat <<EOF
Commands:
  Sync now:       gdmount sync
  Download mode:  gdmount mode [all|selected]
  Chosen folders: gdmount local [list|add|remove]
  Status:         gdmount status
  Unmount/stop:   gdmount stop
  Mount/start:    gdmount start
  Other account:  gdmount switch-account
  Remove all:     gdmount uninstall
  Logs:           journalctl --user -u $SYNC_SERVICE -u $VIEW_SERVICE
EOF
  else
    cat <<EOF
Команди:
  Синхронізувати зараз: gdmount sync
  Режим завантаження:   gdmount mode [all|selected]
  Вибрані теки:         gdmount local [list|add|remove]
  Статус:               gdmount status
  Розмонтувати/зупинити: gdmount stop
  Змонтувати/запустити: gdmount start
  Інший акаунт:         gdmount switch-account
  Видалити все:         gdmount uninstall
  Логи:                 journalctl --user -u $SYNC_SERVICE -u $VIEW_SERVICE
EOF
  fi
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
PENDING_UPLOADS=0
PENDING_DOWNLOADS=0
PENDING_UPLOAD_ITEMS=()

# Count changes detected on each side and collect local changed paths without
# transferring files. Path1 is Google Drive and Path2 is the local copy.
pending_sync_changes() {
  local folder remote_path local_path marker temp_file upload download item targets

  [[ -d "$STATE_DIR" ]] || return 6
  command -v flock >/dev/null 2>&1 || return 4
  have_network || return 3
  ((SYNC_LOCKED)) || return 5
  targets="$(selected_targets "$OFFLINE_ALL" "$OFFLINE_FOLDERS")"
  [[ -n "$targets" ]] || return 2

  # A folder without a bisync marker has no baseline to compare against yet.
  while IFS= read -r folder; do
    if [[ "$folder" == "." ]]; then remote_path="${REMOTE}:"
    else remote_path="${REMOTE}:${folder}"; fi
    marker="$(bisync_marker "$remote_path")"
    [[ -f "$marker" ]] || return 6
  done <<< "$targets"

  PENDING_UPLOADS=0
  PENDING_DOWNLOADS=0
  PENDING_UPLOAD_ITEMS=()
  while IFS= read -r folder; do
    if [[ "$folder" == "." ]]; then
      remote_path="${REMOTE}:"
      local_path="$OFFLINE_DIR"
    else
      remote_path="${REMOTE}:${folder}"
      local_path="$OFFLINE_DIR/$folder"
    fi
    temp_file="$(mktemp)" || return 7
    if ! rclone bisync "$remote_path" "$local_path" --dry-run --verbose \
      --create-empty-src-dirs --conflict-resolve newer --conflict-loser num \
      >"$temp_file" 2>&1; then
      rm -f -- "$temp_file"
      return 8
    fi
    read -r upload download < <(awk '
      /Path2:[[:space:]]+[0-9]+ changes:/ {
        count = $0
        sub(/^.*Path2:[[:space:]]+/, "", count)
        sub(/[[:space:]].*$/, "", count)
        upload += count
      }
      /Path1:[[:space:]]+[0-9]+ changes:/ {
        count = $0
        sub(/^.*Path1:[[:space:]]+/, "", count)
        sub(/[[:space:]].*$/, "", count)
        download += count
      }
      END { printf "%d %d\n", upload, download }
    ' "$temp_file")
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      if [[ "$folder" == "." ]]; then
        PENDING_UPLOAD_ITEMS+=("$item")
      else
        PENDING_UPLOAD_ITEMS+=("$folder/$item")
      fi
    done < <(sed $'s/\033\\[[0-9;]*m//g' "$temp_file" | awk '
      /NOTICE: - Path2[[:space:]]+/ {
        item = $0
        sub(/^.*NOTICE: - Path2[[:space:]]+/, "", item)
        if (item ~ /^File (is new|was deleted)[[:space:]]+- /) {
          sub(/^File (is new|was deleted)[[:space:]]+- /, "", item)
        } else if (item ~ /^File changed: /) {
          sub(/^File changed: /, "", item)
          separator = index(item, " - ")
          if (separator == 0) next
          item = substr(item, separator + 3)
        } else {
          next
        }
        if (item != "") print item
      }
    ')
    rm -f -- "$temp_file"
    PENDING_UPLOADS=$((PENDING_UPLOADS + upload))
    PENDING_DOWNLOADS=$((PENDING_DOWNLOADS + download))
  done <<< "$targets"
}

cmd_status() {
  local item
  echo "${C_BOLD}$(_ "Стан Google Drive")${C_RESET}"

  step "Пакети"
  if command -v rclone >/dev/null; then ok "rclone: %s" "$(rclone version | head -1)"
  else warn "rclone не встановлено"; fi
  if command -v mergerfs >/dev/null || [[ -x "$HOME/.local/bin/mergerfs" ]]; then ok "mergerfs"
  else warn "mergerfs не встановлено"; fi

  step "Remote"
  if command -v rclone >/dev/null && rclone listremotes | grep -Fx "${REMOTE}:" >/dev/null; then
    ok "Remote «%s» налаштовано" "$REMOTE"
    local account
    account="$(current_account || true)"
    info "Акаунт: %s" "${account:-$(_ "не вдалося визначити")}"
  else
    warn "Remote «%s» не знайдено" "$REMOTE"
  fi

  step "Режим"
  if [[ "$OFFLINE_ALL" == "1" ]]; then info "Локальна копія: увесь Google Drive"
  elif [[ -n "$OFFLINE_FOLDERS" ]]; then info "Локально зберігаються лише вибрані теки:"; printf '    %s\n' "${OFFLINE_FOLDERS//$'\n'/$'\n'    }"
  else info "Нічого не вибрано. Дивіться: gdmount mode"; fi

  step "Пристрій «%s»" "$MOUNT_NAME"
  if is_stale; then
    warn "Точка %s «зависла». Виправити: gdmount start" "$MNT"
  elif is_mounted; then
    ok "Змонтовано: %s" "$MNT"
  else
    warn "Не змонтовано: %s. Змонтувати: gdmount start" "$MNT"
  fi

  step "Синхронізація"
  if [[ "$SYNC_MODE" == manual ]]; then
    info "Спосіб синхронізації: ручний"
    info "Фонова синхронізація вимкнена."
    info "Запустити зараз: gdmount sync"
  elif [[ -f "$SYNC_TIMER_FILE" && -f "$SYNC_UNIT_FILE" ]]; then
    info "Спосіб синхронізації: автоматичний, кожні %s" "$SYNC_INTERVAL"
    if systemctl --user is-active --quiet "$SYNC_TIMER" 2>/dev/null; then
      info "Таймер синхронізації активний."
      if systemctl --user is-failed --quiet "$SYNC_SERVICE" 2>/dev/null; then
        warn "Остання фонова синхронізація завершилася помилкою. Журнал: journalctl --user -u %s -n 50" "$SYNC_SERVICE"
      fi
    else
      warn "Автоматичну синхронізацію налаштовано, але таймер неактивний. Запустити: gdmount start"
    fi
    info "Запустити зараз: gdmount sync"
  elif has_selection; then
    warn "Автоматичний режим вибрано, але таймер не налаштовано. Запустити: gdmount start"
  else
    info "Автоматичний режим вибрано, але таймер не запущено: локальні теки не вибрано."
  fi

  step "Черга синхронізації"
  if ! has_selection; then
    info "Нічого не вибрано для синхронізації."
  elif ! command -v rclone >/dev/null 2>&1; then
    warn "Чергу не перевірено: rclone не встановлено."
  elif ! rclone listremotes | grep -Fx "${REMOTE}:" >/dev/null; then
    warn "Чергу не перевірено: remote «%s» не налаштовано." "$REMOTE"
  elif ! have_network; then
    warn "Чергу не перевірено: немає зв'язку з Google Drive. Локальні зміни залишаються на комп'ютері."
  else
    info "Перевіряю Google Drive без передавання файлів; перевірка може тривати."
    if pending_sync_changes; then
      if (( PENDING_UPLOADS == 0 && PENDING_DOWNLOADS == 0 )); then
        ok "Змін для синхронізації немає."
      else
        if (( PENDING_UPLOADS > 0 )); then
          warn "Локальних змін до відправки: %s" "$PENDING_UPLOADS"
          if ((${#PENDING_UPLOAD_ITEMS[@]})); then
            for item in "${PENDING_UPLOAD_ITEMS[@]}"; do printf '      • %s\n' "$item"; done
          else
            info "Не вдалося отримати перелік локальних файлів."
          fi
        fi
        (( PENDING_DOWNLOADS == 0 )) || warn "Змін з Google Drive до отримання: %s" "$PENDING_DOWNLOADS"
        info "Передати й отримати зміни зараз: gdmount sync"
      fi
    else
      local pending_rc=$?
      case "$pending_rc" in
        3) warn "Чергу не перевірено: немає зв'язку з Google Drive. Локальні зміни залишаються на комп'ютері." ;;
        4) warn "Чергу не перевірено: не знайдено flock для безпечної перевірки." ;;
        5) info "Синхронізація вже виконується; перевірте статус після її завершення." ;;
        6) warn "Початкову синхронізацію ще не завершено. Запустіть: gdmount sync" ;;
        *) warn "Не вдалося перевірити зміни. Локальні файли збережені; спробуйте: gdmount sync" ;;
      esac
    fi
  fi

  step "Місце на диску"
  if [[ -d "$OFFLINE_DIR" ]]; then
    info "Завантажено: %s (%s)" "$(du -sh "$OFFLINE_DIR" 2>/dev/null | cut -f1)" "$OFFLINE_DIR"
    info "Вільно на диску: %s" "$(df -h --output=avail "$OFFLINE_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
  else
    info "Локальних даних немає."
  fi
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
cmd_uninstall() {
  echo "${C_BOLD}$(_ "Видалення gdmount")${C_RESET}"
  echo
  info "Буде виконано:"
  info " • зупинено фонову синхронізацію й розмонтовано %s" "$MNT"
  info " • видалено службові файли systemd, команду gdmount та налаштування"
  info " • запропоную залишити ваші файли у звичайній теці %s" "$MNT"
  info " • окремо запитаю про remote «%s» і пакет rclone" "$REMOTE"
  info "Файли на самому Google Drive НЕ видаляються."
  echo
  ask "Продовжити?" || { info "Скасовано."; exit 0; }

  step "1/4 Зупинка"
  systemctl --user show-environment >/dev/null || die "Керування службами користувача systemd недоступне."
  stop_drive || die "Не вдалося зупинити Google Drive. Перевірте служби systemd і повторіть."
  if [[ -f "$SYNC_TIMER_FILE" ]]; then systemctl --user disable "$SYNC_TIMER"; fi
  if [[ -f "$VIEW_UNIT_FILE" ]]; then systemctl --user disable "$VIEW_SERVICE"; fi
  ok "Службу зупинено"

  step "2/4 Службові файли"
  rm -f "$VIEW_UNIT_FILE" "$SYNC_UNIT_FILE" "$SYNC_TIMER_FILE"
  systemctl --user daemon-reload
  systemctl --user reset-failed "$VIEW_SERVICE" "$SYNC_SERVICE" >/dev/null 2>&1 || true
  if state_is MERGERFS_STATIC_INSTALLED; then
    rm -f "$HOME/.local/bin/mergerfs"
    ok "Видалено mergerfs static build, встановлений gdmount"
  fi
  ok "Видалено службові файли"

  step "3/4 Ваші файли"
  if [[ -d "$OFFLINE_DIR" && -n "$(ls -A "$OFFLINE_DIR" 2>/dev/null)" ]] && ! is_mounted; then
    if ask "Залишити завантажені файли у звичайній теці %s?" "$MNT"; then
      if rmdir "$MNT" 2>/dev/null || [[ ! -e "$MNT" ]]; then
        mkdir -p "$(dirname "$MNT")"
        mv -- "$OFFLINE_DIR" "$MNT"
        ok "Файли перенесено у %s" "$MNT"
      else
        warn "%s не порожня. Ваші файли залишено в %s" "$MNT" "$OFFLINE_DIR"
      fi
    else
      info "Файли залишено в %s" "$OFFLINE_DIR"
    fi
  else
    rmdir "$MNT" 2>/dev/null || true
    [[ -d "$OFFLINE_DIR" ]] && rmdir "$OFFLINE_DIR" 2>/dev/null || true
    info "Нічого переносити"
  fi
  [[ -d "$OFFLINE_ARCHIVE" ]] && info "Архів старих копій: %s" "$OFFLINE_ARCHIVE"

  step "4/4 Remote та пакет"
  # Is there a record of what this script created? If the state file is absent,
  # ownership is unknown (for example, configured by an older script version).
  local known=0 remote_kept=0 pkg_kept=0 created_remote
  [[ -f "$STATE_FILE" ]] && known=1
  created_remote="$(state_get REMOTE_CREATED_NAME || true)"

  if command -v rclone >/dev/null && rclone listremotes | grep -Fx "${REMOTE}:" >/dev/null; then
    if [[ -n "$created_remote" && "$created_remote" != "$REMOTE" ]] ||
       { [[ $known -eq 1 && -z "$created_remote" ]] && ! state_is REMOTE_CREATED; }; then
      info "Remote «%s» існував до цього скрипта, не чіпаю." "$REMOTE"
    else
      [[ -n "$created_remote" ]] || warn "Немає запису, хто створив remote «%s» (можливо, стара версія скрипта)." "$REMOTE"
      if [[ -z "$created_remote" && $ASSUME_YES -eq 1 ]]; then
        warn "З --yes remote невідомого походження не видаляю. Видаліть вручну: rclone config delete %s" "$REMOTE"
      elif ask "Видалити remote «%s» (токен доступу з rclone.conf)?" "$REMOTE"; then
        rclone config delete "$REMOTE"
        state_set REMOTE_CREATED_NAME ""
        state_set REMOTE_CREATED 0
        ok "Remote видалено"
        info "Щоб повністю відкликати доступ, зайдіть на https://myaccount.google.com/permissions"
      else
        info "Remote залишено (видалити пізніше: rclone config delete %s)" "$REMOTE"
        [[ -z "$created_remote" ]] || remote_kept=1
      fi
    fi
  else
    info "Remote не знайдено, пропускаю"
  fi

  if command -v rclone >/dev/null; then
    if [[ $known -eq 1 ]] && ! state_is PKG_INSTALLED; then
      info "rclone не встановлювався цим скриптом, пакет не чіпаю."
    else
      [[ $known -eq 0 ]] && warn "Немає запису, чи встановлював rclone цей скрипт."
      if [[ $known -eq 0 && $ASSUME_YES -eq 1 ]]; then
        warn "З --yes пакет невідомого походження не видаляю."
      elif ask "Видалити пакет rclone?"; then
        pkg_remove rclone || die "Не вдалося видалити пакет rclone. Повторіть gdmount uninstall."
        ok "Пакет rclone видалено"
        info "Пакет fuse3 залишено, бо його можуть використовувати інші програми."
      else
        info "Пакет залишено"
        state_is PKG_INSTALLED && pkg_kept=1
      fi
    fi
  fi

  rm -f "$STATE_DIR"/bisync-*
  # Remove the state file only if nothing remains for the next uninstall
  if [[ $remote_kept -eq 0 && $pkg_kept -eq 0 ]]; then
    rm -f "$CONF_FILE" "$STATE_FILE"
  else
    info "Запис стану збережено, щоб наступний uninstall знову запитав про залишене."
  fi
  echo
  echo "${C_BOLD}${C_GREEN}$(_ "Видалення gdmount завершено.")${C_RESET}"
  # Remove the installed command last (the script itself may be running from it)
  rm -f "$CLI_PATH" "$I18N_PATH"
  rmdir "$I18N_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# switch-account
# ---------------------------------------------------------------------------
cmd_switch_account() {
  [[ $EUID -ne 0 ]] || die "Не запускайте від root."
  command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: gdmount install"
  rclone listremotes | grep -Fx "${REMOTE}:" >/dev/null \
    || die "Remote «%s» не знайдено. Спершу виконайте: gdmount install" "$REMOTE"
  have_network || die "Для зміни акаунту потрібен інтернет. Підключіться до мережі й повторіть."
  validate_offline_dir || die "Тека локальних даних має бути окремо від теки монтування."
  prepare_rclone_auth_port || die "Порт входу Google зайнятий. Звільніть порт %s і повторіть: gdmount switch-account" "$RCLONE_AUTH_PORT"
  has_terminal || die "Для зміни акаунта запустіть gdmount switch-account у терміналі."
  systemctl --user show-environment >/dev/null || die "Керування службами користувача systemd недоступне."

  echo "${C_BOLD}$(_ "Зміна акаунту Google Drive")${C_RESET}"
  local old_account new_account
  old_account="$(current_account)"
  info "Remote:          %s" "$REMOTE"
  info "Поточний акаунт: %s" "${old_account:-$(_ "не вдалося визначити")}"
  info "Локальні копії старого акаунту буде збережено в архіві, а що завантажувати з нового акаунту — потрібно обрати знову."
  ask "Продовжити?" || { info "Скасовано."; return 0; }

  step "1/3 Зупинка"
  remember_running_units
  RESTORE_RUNNING_UNITS=1
  stop_drive || die "Не вдалося зупинити Google Drive. Перевірте служби systemd і повторіть."
  if has_selection; then
    sync_offline_folders || die "Не вдалося синхронізувати зміни зі старим акаунтом. Попередній акаунт залишається активним."
  fi

  step "2/3 Авторизація нового акаунту"
  info "Зараз відкриється браузер."
  warn "Google може автоматично підставити СТАРИЙ акаунт. Оберіть «Використати інший акаунт» або скопіюйте посилання з термінала в приватне вікно браузера."
  info "Якщо rclone спитає про auto config, відповідайте y (Yes)."
  stage_remote_reconnect || die "Не вдалося підтвердити доступ нового акаунта. Попередній акаунт залишається активним."
  new_account="$(current_account --config "$STAGED_RCLONE_CONFIG")"
  verify_staged_remote
  if [[ -n "$old_account" && "$old_account" == "$new_account" ]]; then
    apply_staged_remote
    warn "Це той самий акаунт, що й раніше. Щоб обрати інший, запустіть команду ще раз і в браузері виберіть інший акаунт Google."
    restore_running_units || return 1
    return 0
  fi

  archive_account_copy
  reset_account_selection
  apply_staged_remote
  update_sync_timer

  step "3/3 Запуск"
  ok "Авторизовано акаунт: %s" "${new_account:-$(_ "не вдалося визначити")}"
  info "Оберіть, що завантажувати з нового акаунту: gdmount mode all або gdmount mode selected"
  restore_running_units
}

# ---------------------------------------------------------------------------
# start / stop
# ---------------------------------------------------------------------------
cmd_stop() {
  systemctl --user show-environment >/dev/null || die "Керування службами користувача systemd недоступне."
  stop_drive || die "Не вдалося зупинити Google Drive. Перевірте служби systemd і повторіть."
  ok "Пристрій розмонтовано, фонову синхронізацію зупинено. Запустити знову: gdmount start"
}

cmd_start() {
  [[ -f "$VIEW_UNIT_FILE" ]] || die "gdmount не встановлено. Виконайте: gdmount install"
  if is_stale; then
    systemctl --user stop "$VIEW_SERVICE"
    do_unmount "$MNT" || die "Не вдалося розмонтувати %s. Закрийте програми, що використовують диск, і повторіть." "$MNT"
  fi
  systemctl --user start "$VIEW_SERVICE"
  wait_for_mount 15 || die "Монтування не з'явилося. Логи: journalctl --user -u %s -n 50" "$VIEW_SERVICE"
  if [[ "$SYNC_MODE" == auto ]] && has_selection; then
    if [[ -f "$SYNC_TIMER_FILE" && -f "$SYNC_UNIT_FILE" ]]; then
      systemctl --user start "$SYNC_TIMER"
    else
      update_sync_timer
    fi
  fi
  ok "Змонтовано: %s" "$MNT"
}

set_sync_interval_arg() {
  local value="$1"
  if [[ "$value" =~ ^0+(s|sec|m|min|h|d)?$ ]]; then
    SYNC_MODE=manual
    SYNC_MODE_FROM_FLAG=1
    return 0
  fi
  SYNC_INTERVAL="$value"
  SYNC_INTERVAL_FROM_FLAG=1
  # Supplying a non-zero interval is an explicit request for periodic sync,
  # unless a sync mode was already supplied in the same command.
  if [[ $SYNC_MODE_FROM_FLAG -eq 0 ]]; then SYNC_MODE=auto; fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)        REMOTE="${2:?$(_ "Потрібне значення для %s" --remote)}"; shift 2 ;;
    --mount)         MNT="${2:?$(_ "Потрібне значення для %s" --mount)}"; MNT_FROM_FLAG=1; shift 2 ;;
    --sync-mode|--sync-method|--refresh-mode)
      SYNC_MODE="${2:?$(_ "Потрібне значення для %s" "$1")}"
      SYNC_MODE_FROM_FLAG=1
      shift 2
      ;;
    --sync-interval|--poll-interval)
      set_sync_interval_arg "${2:?$(_ "Потрібне значення для %s" "$1")}"; shift 2
      ;;
    --folder)        SCOPE_FOLDER_FLAGS+=("${2:?$(_ "Потрібне значення для %s" --folder)}"); shift 2 ;;
    --all)           SCOPE_ALL_FLAG=1; shift ;;
    --background)    BACKGROUND=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage ;;
    -*)              die "Невідома опція: %s (див. --help)" "$1" ;;
    *)               if [[ "$COMMAND" == "mode" && -z "$MODE_ARG" ]]; then
                       MODE_ARG="$1"; shift
                     elif [[ "$COMMAND" == "sync-mode" && -z "$SYNC_MODE_ARG" ]]; then
                       SYNC_MODE_ARG="$1"; shift
                     elif [[ "$COMMAND" == "local" || "$COMMAND" == "offline" ]] && [[ -z "$OFFLINE_ACTION" ]]; then
                       OFFLINE_ACTION="$1"; shift
                     elif [[ ( "$COMMAND" == "local" || "$COMMAND" == "offline" ) && -z "$OFFLINE_PATH" ]]; then
                       OFFLINE_PATH="$1"; shift
                     else
                       die "Зайвий аргумент: %s (див. --help)" "$1"
                     fi ;;
  esac
done

MNT="$(realpath -ms -- "$MNT")"
CONFIGURED_MOUNT="$(realpath -ms -- "$CONFIGURED_MOUNT")"
if [[ -n "$CONFIGURED_REMOTE" && "$REMOTE" != "$CONFIGURED_REMOTE" ]]; then
  [[ "$COMMAND" == install ]] || die "Активний remote «%s». Команда для зміни підключення — gdmount install --remote %q" "$CONFIGURED_REMOTE" "$REMOTE"
  # A different remote must not inherit the old selection.
  OFFLINE_ALL=0
  OFFLINE_FOLDERS=""
fi
if [[ -z "$CONFIGURED_REMOTE" ]] && has_local_copy; then
  case "$COMMAND" in
    sync|local|offline|mode|switch-account|switch)
      if ((gdmount_lock_required)); then
        die "Знайдено локальні дані без налаштованого remote. Виконайте gdmount install, щоб зберегти їх окремо."
      fi
      ;;
  esac
fi

# Normalize selections saved by older versions before comparing paths.
saved_folders="$OFFLINE_FOLDERS"
OFFLINE_FOLDERS=""
while IFS= read -r _f; do
  [[ -n "$_f" ]] || continue
  add_offline_folder "$_f"
done <<< "$saved_folders"

# Install flags choose what to download (they replace any earlier selection)
PREV_ALL="$OFFLINE_ALL"; PREV_FOLDERS="$OFFLINE_FOLDERS"
if (( SCOPE_ALL_FLAG )) && (( ${#SCOPE_FOLDER_FLAGS[@]} )); then
  die "Використовуйте або --all, або --folder, але не разом."
fi
if (( SCOPE_ALL_FLAG )); then
  [[ "$COMMAND" == install ]] || die "Опція %s доступна лише для gdmount install." --all
  OFFLINE_ALL=1; OFFLINE_FOLDERS=""
elif (( ${#SCOPE_FOLDER_FLAGS[@]} )); then
  [[ "$COMMAND" == install ]] || die "Опція %s доступна лише для gdmount install." --folder
  OFFLINE_ALL=0; OFFLINE_FOLDERS=""
  for _f in "${SCOPE_FOLDER_FLAGS[@]}"; do add_offline_folder "$_f"; done
fi

case "$COMMAND" in
  install)   cmd_install ;;
  local|offline) cmd_offline ;;
  status)    cmd_status ;;
  sync)      cmd_sync ;;
  mode)      cmd_mode ;;
  sync-mode) cmd_sync_mode ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  switch-account|switch) cmd_switch_account ;;
  uninstall) cmd_uninstall ;;
  -h|--help|help) usage ;;
  *)         die "$(_ "Невідома команда: %s" "$COMMAND"). $(_ "Доступні команди: install, sync, sync-mode, mode, local, status, start, stop, switch-account, uninstall")" ;;
esac
