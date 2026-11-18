#!/usr/bin/env bash
#
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Pan Vena
#
# gdmount: mount Google Drive with rclone | монтування Google Drive через rclone
# Run locally: ./gdrive-mount.sh install
# Install remotely: curl -fsSL https://github.com/PanVena/gdmount/raw/refs/heads/main/gdrive-mount.sh | bash -s -- install
#
# EN: Installs rclone/fuse3, authorizes Google, mounts ~/GoogleDrive, and adds a systemd service.
# UA: Встановлює rclone/fuse3, авторизує Google, монтує ~/GoogleDrive і додає службу systemd.
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
if [[ -n "$GDMOUNT_SOURCE" && -f "$GDMOUNT_SOURCE" ]]; then
  GDMOUNT_SCRIPT_DIR="$(cd -- "$(dirname -- "$GDMOUNT_SOURCE")" && pwd)"
  SELF="$(readlink -f "$GDMOUNT_SOURCE")"
else
  GDMOUNT_BOOTSTRAP_DIR="$(mktemp -d)"
  GDMOUNT_SCRIPT_DIR="$GDMOUNT_BOOTSTRAP_DIR"
  SELF="$GDMOUNT_BOOTSTRAP_DIR/gdrive-mount.sh"
  if ! command -v curl >/dev/null 2>&1 ||
    ! curl -fsSL "https://raw.githubusercontent.com/PanVena/gdmount/main/gdrive-mount.sh" -o "$SELF" ||
    ! curl -fsSL "https://raw.githubusercontent.com/PanVena/gdmount/main/i18n.sh" -o "$GDMOUNT_BOOTSTRAP_DIR/i18n.sh"; then
    printf 'gdmount: could not download the installer files required for streamed installation.\n' >&2
    rm -rf -- "$GDMOUNT_BOOTSTRAP_DIR"
    exit 1
  fi
  trap 'rm -rf -- "$GDMOUNT_BOOTSTRAP_DIR"' EXIT
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
if [[ -z "${GDMOUNT_UI_LANG:-}" ]]; then
  GDMOUNT_UI_LANG="$(gdmount_detect_lang)"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONF_FILE="$HOME/.config/rclone-gdrive-setup/config"
# Values saved during install (environment variables and flags take priority)
# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
# The old config format stored intervals explicitly; they now depend on the mode
if [[ -f "$CONF_FILE" && "${GDRIVE_CONF_VERSION:-1}" != "2" ]]; then
  unset GDRIVE_POLL_INTERVAL GDRIVE_DIR_CACHE_TIME
fi

REMOTE="${GDRIVE_REMOTE:-gdrive}"
MNT="${GDRIVE_MOUNT:-$HOME/GoogleDrive}"
CACHE_SIZE="${GDRIVE_CACHE_SIZE:-5G}"
CACHE_AGE="${GDRIVE_CACHE_AGE:-30d}"
REFRESH_MODE="${GDRIVE_REFRESH_MODE:-manual}"   # manual: оновлюєте самі (gdmount refresh); auto: rclone опитує Google
POLL_INTERVAL="${GDRIVE_POLL_INTERVAL:-}"       # порожньо = за режимом (manual: 0, auto: 1m)
DIR_CACHE_TIME="${GDRIVE_DIR_CACHE_TIME:-}"     # порожньо = за режимом (manual: 1000h, auto: 5m)
WRITE_BACK="${GDRIVE_WRITE_BACK:-30s}"       # затримка перед вивантаженням закритого файлу
ASSUME_YES=0

SERVICE_NAME="rclone-gdrive.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/$SERVICE_NAME"
WATCH_SERVICE="rclone-gdrive-watch.service"   # запускає монтування, коли з'являється мережа
WATCH_UNIT_FILE="$UNIT_DIR/$WATCH_SERVICE"
WATCH_SCRIPT="$HOME/.local/bin/rclone-gdrive-watch"
CACHE_DIR="$HOME/.cache/rclone-gdrive"   # окрема тека, щоб безпечно видаляти
STATE_DIR="$HOME/.config/rclone-gdrive-setup"
STATE_FILE="$STATE_DIR/state"            # що саме створив цей скрипт
RC_ADDR="${GDRIVE_RC_ADDR:-127.0.0.1:5572}"   # локальний канал керування rclone (для refresh)
RC_ENV="$STATE_DIR/rc.env"                    # логін/пароль каналу, права 600
CLI_DIR="$HOME/.local/bin"
CLI_PATH="$CLI_DIR/gdmount"
I18N_DIR="$HOME/.local/share/gdmount"
I18N_PATH="$I18N_DIR/i18n.sh"
REFRESH_PATH=""; RECURSIVE=0; REFRESH_ALL=0; MODE_ARG=""; POLL_FROM_FLAG=0

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step() { local m; m="$(_ "$*")"; echo; echo "${C_BOLD}${C_BLUE}==> $m${C_RESET}"; }
info() { local m; m="$(_ "$*")"; echo "    $m"; }
ok()   { local m; m="$(_ "$*")"; echo "    ${C_GREEN}✔${C_RESET} $m"; }
warn() { local m; m="$(_ "$*")"; echo "    ${C_YELLOW}!${C_RESET} $m"; }
err()  { local m; m="$(_ "$*")"; echo "${C_RED}✘ $m${C_RESET}" >&2; }
die()  { err "$*"; exit 1; }

ask() {
  # ask "Question?" -> 0 for yes
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local reply
  local prompt
  prompt="$(_ "$1")"
  read -r -p "    $prompt [y/N] " reply
  [[ "$reply" =~ ^[YyТтСс]$ ]]
}

usage() {
  if [[ "${GDMOUNT_UI_LANG:-uk}" == en ]]; then
    cat <<'EOF'
gdmount - mount Google Drive through rclone

Usage: gdmount COMMAND [OPTIONS]

Commands:
  install [options]         install and mount
  refresh [PATH] [-r|--all] refresh directory-list cache
  mode [manual|auto]        show or change refresh mode
  status                    service, mount and cache status
  start                     start the drive and network auto-start
  stop                      stop the drive and network auto-start
  switch-account [options]  switch Google account
  uninstall [options]       remove files and settings created by the script

Refresh modes:
  manual  poll Google never; refresh manually with gdmount refresh
  auto    poll Google every minute

Options:
  --remote NAME          rclone remote name (GDRIVE_REMOTE, default: gdrive)
  --mount PATH           mount directory (GDRIVE_MOUNT, default: ~/GoogleDrive)
  --cache-size SIZE      maximum file cache size (default: 5G)
  --cache-age TIME       file cache retention time (default: 30d)
  --refresh-mode MODE    manual or auto (default: manual)
  --poll-interval TIME   poll interval; manual: 0, auto: 1m
  --write-back TIME      delay before uploading a closed file (default: 30s)
  --yes, -y              do not ask for confirmation
  -r, --recursive        include subdirectories for refresh PATH
  --all                  refresh the whole drive
  -h, --help             show help

Interface language: GDMOUNT_UI_LANG=uk|en
EOF
  else
    cat <<'EOF'
gdmount - монтування Google Drive через rclone

Використання: gdmount КОМАНДА [ОПЦІЇ]

Команди:
  install [опції]           встановити й змонтувати
  refresh [ТЕКА] [-r|--all] оновити кеш списків тек
  mode [manual|auto]        показати або змінити режим оновлення
  status                    стан служби, монтування та кешу
  start                     запустити диск і автозапуск за мережею
  stop                      зупинити диск і автозапуск за мережею
  switch-account [опції]    змінити акаунт Google
  uninstall [опції]         видалити файли й налаштування, створені скриптом

Режими оновлення:
  manual  не опитувати Google; оновлювати командою gdmount refresh
  auto    опитувати Google раз на хвилину

Опції:
  --remote ІМ'Я          імʼя rclone remote (GDRIVE_REMOTE, типово: gdrive)
  --mount ШЛЯХ           тека монтування (GDRIVE_MOUNT, типово: ~/GoogleDrive)
  --cache-size РОЗМІР    максимальний розмір кешу файлів (типово: 5G)
  --cache-age ЧАС        час збереження файлів у кеші (типово: 30d)
  --refresh-mode РЕЖИМ   manual або auto (типово: manual)
  --poll-interval ЧАС    як часто опитувати Google: manual = 0, auto = 1m
  --write-back ЧАС       затримка перед вивантаженням закритого файлу (типово: 30s)
  --yes, -y              не питати підтвердження
  -r, --recursive        разом із підтеками для refresh ТЕКА
  --all                  оновити весь диск
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

# Resolve intervals from the selected mode (explicit values take priority)
resolve_mode() {
  case "$REFRESH_MODE" in
    manual) EFF_POLL="${POLL_INTERVAL:-0}";  EFF_DIR="${DIR_CACHE_TIME:-1000h}" ;;
    auto)   EFF_POLL="${POLL_INTERVAL:-1m}"; EFF_DIR="${DIR_CACHE_TIME:-5m}" ;;
    *)      die "Невідомий режим «$REFRESH_MODE». Доступні: manual, auto" ;;
  esac
}

# Save settings so gdmount can use them without command-line flags
save_config() {
  mkdir -p "$STATE_DIR"
  {
    echo "# Saved by install. Change with: gdmount install [options]"
    printf ': ${GDRIVE_REMOTE:=%q}\n'         "$REMOTE"
    printf ': ${GDRIVE_MOUNT:=%q}\n'          "$MNT"
    printf ': ${GDRIVE_CACHE_SIZE:=%q}\n'     "$CACHE_SIZE"
    printf ': ${GDRIVE_CACHE_AGE:=%q}\n'      "$CACHE_AGE"
    printf ': ${GDRIVE_CONF_VERSION:=2}\n'
    printf ': ${GDRIVE_REFRESH_MODE:=%q}\n'    "$REFRESH_MODE"
    # Write intervals only when explicitly set; otherwise, derive them from the mode
    if [[ -n "$DIR_CACHE_TIME" ]]; then printf ': ${GDRIVE_DIR_CACHE_TIME:=%q}\n' "$DIR_CACHE_TIME"; fi
    if [[ -n "$POLL_INTERVAL" ]]; then printf ': ${GDRIVE_POLL_INTERVAL:=%q}\n' "$POLL_INTERVAL"; fi
    printf ': ${GDRIVE_WRITE_BACK:=%q}\n'     "$WRITE_BACK"
    printf ': ${GDRIVE_RC_ADDR:=%q}\n'        "$RC_ADDR"
  } > "$CONF_FILE"
}

# Generate a random login/password for the local rclone control channel (once)
make_rc_credentials() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  if [[ ! -f "$RC_ENV" ]]; then
    local pass
    pass="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    ( umask 077; printf 'RCLONE_RC_USER=gdmount\nRCLONE_RC_PASS=%s\n' "$pass" > "$RC_ENV" )
  fi
}

# Call rclone RC using credentials from the file (this is a local socket, not the Google API)
rc_run() {
  [[ -f "$RC_ENV" ]] || die "Немає ключа керування. Виконайте: gdmount install"
  local user pass out
  user="$(grep -m1 '^RCLONE_RC_USER=' "$RC_ENV" | cut -d= -f2-)"
  pass="$(grep -m1 '^RCLONE_RC_PASS=' "$RC_ENV" | cut -d= -f2-)"
  if ! out="$(rclone rc --url "http://${RC_ADDR}" --user "$user" --pass "$pass" "$@" 2>&1)"; then
    err "Не вдалося виконати команду через rclone rc:"
    err "  $out"
    err "Якщо сервіс створено старою версією скрипта, виконайте: gdmount install"
    exit 1
  fi
}

# Copy the script to ~/.local/bin/gdmount so it can be run as a regular command
install_cli() {
  mkdir -p "$CLI_DIR"
  mkdir -p "$I18N_DIR"
  if [[ -f "$GDMOUNT_SCRIPT_DIR/i18n.sh" ]]; then
    install -m 644 "$GDMOUNT_SCRIPT_DIR/i18n.sh" "$I18N_PATH"
  fi
  if [[ "$SELF" != "$(readlink -f "$CLI_PATH" 2>/dev/null || true)" ]]; then
    install -m 755 "$SELF" "$CLI_PATH"
  fi
  ok "Команду встановлено: gdmount ($CLI_PATH)"
  case ":$PATH:" in
    *":$CLI_DIR:"*) ;;
    *) warn "$CLI_DIR немає в PATH. Додайте в ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
}

# Check whether the internet is available (fast DNS check, independent of the rclone token)
have_network() { getent hosts www.googleapis.com >/dev/null 2>&1; }

# Count files waiting to upload to Google Drive.
# When the service is running, query the rclone queue. Otherwise, look for “Dirty”
# markers in cache metadata (rclone stores files that have not uploaded for the next mount).
pending_uploads() {
  local n=0 user pass out
  if [[ -f "$RC_ENV" ]] && command -v rclone >/dev/null \
     && systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    user="$(grep -m1 '^RCLONE_RC_USER=' "$RC_ENV" | cut -d= -f2-)"
    pass="$(grep -m1 '^RCLONE_RC_PASS=' "$RC_ENV" | cut -d= -f2-)"
    if out="$(rclone rc --url "http://${RC_ADDR}" --user "$user" --pass "$pass" vfs/queue 2>/dev/null)"; then
      n="$(grep -cE '"name":' <<<"$out" || true)"
      echo "${n:-0}"; return 0
    fi
  fi
  if [[ -d "$CACHE_DIR/vfsMeta" ]]; then
    n="$(grep -rlE '"Dirty":[[:space:]]*true' "$CACHE_DIR/vfsMeta" 2>/dev/null | wc -l || true)"
  fi
  echo "${n:-0}"
}

# Wait until the upload queue empties (up to $1 seconds, default 180).
# 0: everything uploaded or waiting is unnecessary (service/network unavailable)
# 1: files remain after the wait
wait_for_uploads() {
  local limit="${1:-180}" waited=0 n
  n="$(pending_uploads)"
  [[ "${n:-0}" -gt 0 ]] || return 0
  { systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null && is_mounted && have_network; } || return 0
  info "Чекаю, поки вивантажаться файли ($n), до ${limit} с..."
  while (( waited < limit )); do
    sleep 5; waited=$((waited + 5))
    n="$(pending_uploads)"
    if [[ "${n:-0}" -eq 0 ]]; then ok "Усе вивантажено."; return 0; fi
  done
  warn "Досі не вивантажено файлів: $n"
  return 1
}

# Before removing the cache: warn if it contains changes absent from Google Drive
confirm_cache_removal() {
  [[ -d "$CACHE_DIR" ]] || return 0
  local n; n="$(pending_uploads)"
  if [[ "${n:-0}" -gt 0 ]]; then
    warn "У кеші $n файл(ів) ще не вивантажено на Google Drive."
    warn "Після очищення ці зміни буде втрачено. Самі файли лежать у $CACHE_DIR/vfs/"
    [[ $ASSUME_YES -eq 1 ]] && return 1
    ask "Все одно очистити кеш?"
    return
  fi
  have_network && return 0
  warn "Немає зв'язку з Google Drive, тож перевірити, що все вивантажено, неможливо."
  warn "Якщо в кеші ($CACHE_DIR) лежать зміни, яких ще немає на диску, після очищення їх буде втрачено."
  [[ $ASSUME_YES -eq 1 ]] && return 1
  ask "Все одно очистити кеш?"
}

# Restore services stopped by switch-account
restore_services() {
  [[ ${was_active:-0} -eq 1 ]] && systemctl --user start "$SERVICE_NAME" || true
  [[ ${watch_active:-0} -eq 1 ]] && systemctl --user start "$WATCH_SERVICE" || true
}

# The mount point exists but is inaccessible (the rclone process stopped)
is_stale() { is_mounted && ! stat "$MNT" >/dev/null 2>&1; }

# Email of the account linked to the remote (empty if it could not be determined)
current_account() {
  rclone config userinfo "${REMOTE}:" 2>/dev/null \
    | awk 'tolower($1)=="email:" {print $2; exit}' || true
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
  else warn "Невідомий пакетний менеджер, видаліть пакет $* вручну."; return 1
  fi
}

do_unmount() {
  is_mounted || return 0
  if   command -v fusermount3 >/dev/null; then fusermount3 -u "$MNT" 2>/dev/null || fusermount3 -uz "$MNT"
  elif command -v fusermount  >/dev/null; then fusermount  -u "$MNT" 2>/dev/null || fusermount  -uz "$MNT"
  else umount "$MNT"
  fi
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
cmd_install() {
  [[ $EUID -ne 0 ]] || die "Не запускайте від root: сервіс має працювати від вашого користувача."

  echo "${C_BOLD}$(_ "Налаштування Google Drive через rclone")${C_RESET}"
  info "Remote:       $REMOTE"
  info "Теку монтування: $MNT"
  info "Ліміт кешу:   $CACHE_SIZE, зберігання до $CACHE_AGE (тека кешу: $CACHE_DIR)"
  info "Режим оновлення: $REFRESH_MODE (опитування Google: $([[ "$EFF_POLL" == "0" ]] && echo вимкнено || echo "кожні $EFF_POLL")), вивантаження файлів через $WRITE_BACK після закриття"

  step "1/5 Перевірка rclone та FUSE"
  if command -v rclone >/dev/null; then
    ok "rclone вже встановлено: $(rclone version | head -1)"
  else
    info "Встановлюю rclone та fuse3 (потрібен sudo)..."
    pkg_install rclone fuse3
    state_set PKG_INSTALLED 1
    ok "Встановлено: $(rclone version | head -1)"
  fi
  command -v fusermount3 >/dev/null || command -v fusermount >/dev/null \
    || die "fusermount не знайдено. Встановіть пакет fuse3."
  RCLONE_BIN="$(command -v rclone)"
  FUSERMOUNT_BIN="$(command -v fusermount3 || command -v fusermount)"

  step "2/5 Remote «$REMOTE» для Google Drive"
  have_network || die "Немає з'єднання з інтернетом. Підключіться до мережі й повторіть."
  if rclone listremotes | grep -qx "${REMOTE}:"; then
    ok "Remote вже існує, авторизацію пропускаю."
  else
    info "Зараз відкриється браузер для входу в Google-акаунт."
    info "(Без графічної сесії: виконайте 'rclone authorize drive' на іншій машині.)"
    rclone config create "$REMOTE" drive scope=drive
    state_set REMOTE_CREATED 1
    ok "Remote створено."
  fi

  info "Перевіряю доступ до диска..."
  if rclone lsd "${REMOTE}:" --max-depth 1 >/dev/null 2>&1; then
    ok "Доступ до Google Drive є."
  else
    die "Не вдалося отримати доступ до ${REMOTE}:. Перевірте: rclone config reconnect ${REMOTE}:"
  fi

  step "3/5 Тека монтування"
  if is_stale; then
    warn "Знайдено «завислу» точку монтування (залишок від попереднього запуску rclone)."
    if do_unmount; then
      ok "Завислу точку розмонтовано"
    else
      die "Не вдалося розмонтувати. Виконайте вручну: fusermount3 -uz \"$MNT\""
    fi
  fi
  if [[ -d "$MNT" ]]; then
    if is_mounted; then
      info "Вже змонтовано, перемонтую після оновлення сервісу."
    elif [[ -n "$(ls -A "$MNT" 2>/dev/null)" ]]; then
      die "$MNT не порожня. Оберіть іншу теку (--mount) або очистіть цю."
    else
      ok "Тека існує і порожня: $MNT"
    fi
  else
    mkdir -p "$MNT"
    state_set MNT_CREATED 1
    ok "Створено $MNT"
  fi
  mkdir -p "$CACHE_DIR"

  step "4/5 systemd-сервіс користувача"
  mkdir -p "$UNIT_DIR"
  make_rc_credentials

  # With NetworkManager: start on the network-available event (no polling).
  # Otherwise: retry automatically every 10 seconds as a fallback.
  local use_watch=0 pre_line="" install_block="" restart_sec=10
  if command -v nmcli >/dev/null && command -v nm-online >/dev/null; then
    use_watch=1
    NM_ONLINE_BIN="$(command -v nm-online)"
    NMCLI_BIN="$(command -v nmcli)"
    pre_line="ExecStartPre=${NM_ONLINE_BIN} -q -t 0"
    restart_sec=30
  else
    install_block=$'\n[Install]\nWantedBy=default.target'
  fi

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Google Drive (rclone mount ${REMOTE}:)

[Service]
Type=notify
EnvironmentFile=${RC_ENV}
${pre_line}
ExecStart=${RCLONE_BIN} mount "${REMOTE}:" "${MNT}" \\
  --vfs-cache-mode full \\
  --vfs-cache-max-size ${CACHE_SIZE} \\
  --vfs-cache-max-age ${CACHE_AGE} \\
  --dir-cache-time ${EFF_DIR} \\
  --poll-interval ${EFF_POLL} \\
  --vfs-write-back ${WRITE_BACK} \\
  --cache-dir "${CACHE_DIR}" \\
  --contimeout 15s \\
  --timeout 30s \\
  --vfs-cache-poll-interval 10m \\
  --rc --rc-addr ${RC_ADDR} \\
  --log-level INFO
ExecStop=${FUSERMOUNT_BIN} -u "${MNT}"
ExecStopPost=-${FUSERMOUNT_BIN} -uz "${MNT}"
Restart=on-failure
RestartSec=${restart_sec}
${install_block}
EOF
  ok "Записано $UNIT_FILE"

  if [[ $use_watch -eq 1 ]]; then
    mkdir -p "$(dirname "$WATCH_SCRIPT")"
    cat > "$WATCH_SCRIPT" <<EOF
#!/usr/bin/env bash
# Starts ${SERVICE_NAME} when network access becomes available.
# No polling: nmcli monitor waits until NetworkManager reports a change.
check() {
  if ${NM_ONLINE_BIN} -q -t 0 && ! systemctl --user is-active --quiet ${SERVICE_NAME}; then
    systemctl --user start --no-block ${SERVICE_NAME}
  fi
}
check
${NMCLI_BIN} monitor | while read -r _; do check; done
EOF
    chmod +x "$WATCH_SCRIPT"
    cat > "$WATCH_UNIT_FILE" <<EOF
[Unit]
Description=Google Drive: монтування при появі мережі

[Service]
ExecStart=${WATCH_SCRIPT}
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF
    ok "Записано $WATCH_UNIT_FILE та $WATCH_SCRIPT"
    systemctl --user daemon-reload
    systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl --user enable --now "$WATCH_SERVICE" >/dev/null 2>&1
    systemctl --user restart "$SERVICE_NAME"
    ok "Автозапуск налаштовано: диск монтується, лише коли з'являється мережа."
    info "Без мережі нічого не працює й не опитує систему (CPU не витрачається)."
  else
    if [[ -f "$WATCH_UNIT_FILE" ]]; then
      systemctl --user disable --now "$WATCH_SERVICE" >/dev/null 2>&1 || true
      rm -f "$WATCH_UNIT_FILE" "$WATCH_SCRIPT"
    fi
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl --user restart "$SERVICE_NAME"
    ok "Сервіс увімкнено (автозапуск при вході в систему)."
    warn "NetworkManager не знайдено: без мережі сервіс повторює спробу кожні 10 с."
  fi

  step "5/5 Очікування монтування"
  for _ in $(seq 1 30); do
    is_mounted && break
    sleep 1
  done
  if is_mounted; then
    ok "Google Drive змонтовано в $MNT"
  else
    err "Монтування не з'явилося за 30 с. Подивіться логи:"
    err "  journalctl --user -u $SERVICE_NAME -n 50"
    exit 1
  fi

  save_config
  step "Команда gdmount"
  install_cli

  local mode_note
  if [[ "$REFRESH_MODE" == "manual" ]]; then
    mode_note="$(_ "Режим manual: Google сам не опитується (змінити: gdmount mode auto).")"
  else
    mode_note="$(_ "Режим auto: Google опитується кожні %s (змінити: gdmount mode manual)." "$EFF_POLL")"
  fi

  if [[ "${GDMOUNT_UI_LANG:-uk}" == en ]]; then
    cat <<EOF

${C_BOLD}Done.${C_RESET} ${mode_note}
Commands:
  Refresh lists: gdmount refresh              (or: gdmount refresh PATH -r, gdmount refresh --all)
  Status:         gdmount status
  Stop:           gdmount stop
  Start:          gdmount start
  Other account:  gdmount switch-account
  Remove all:     gdmount uninstall
  Logs:           journalctl --user -u $SERVICE_NAME -f

${C_YELLOW}Tip:${C_RESET} exclude $MNT from indexing (GNOME: “Search” → “Search Locations”,
KDE: “Search for files”), otherwise the indexer may start downloading the whole drive.
EOF
  else
    cat <<EOF

${C_BOLD}Готово.${C_RESET} ${mode_note}
Команди:
  Оновити списки: gdmount refresh              (або: gdmount refresh ТЕКА -r, gdmount refresh --all)
  Статус:         gdmount status
  Зупинити:       gdmount stop
  Запустити:      gdmount start
  Інший акаунт:   gdmount switch-account
  Видалити все:   gdmount uninstall
  Логи:           journalctl --user -u $SERVICE_NAME -f

${C_YELLOW}Порада:${C_RESET} виключіть $MNT з індексації (GNOME: «Пошук» → «Search Locations»,
KDE: «Пошук файлів»), інакше індексатор може почати качати весь диск.
EOF
  fi
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  echo "${C_BOLD}$(_ "Стан Google Drive (rclone)")${C_RESET}"

  step "Пакет"
  if command -v rclone >/dev/null; then ok "rclone: $(rclone version | head -1)"
  else warn "rclone не встановлено"; fi

  step "Remote"
  if command -v rclone >/dev/null && rclone listremotes | grep -qx "${REMOTE}:"; then
    ok "Remote «$REMOTE» налаштовано"
    info "Акаунт: $(current_account || true)"
  else
    warn "Remote «$REMOTE» не знайдено"
  fi

  step "Сервіс"
  if [[ -f "$UNIT_FILE" ]]; then
    info "Файл: $UNIT_FILE"
    info "Активний:    $(systemctl --user is-active  "$SERVICE_NAME" 2>/dev/null || true)"
    if [[ -f "$WATCH_UNIT_FILE" ]]; then
      info "Автозапуск:  за появою мережі (спостерігач: $(systemctl --user is-active "$WATCH_SERVICE" 2>/dev/null || true))"
    else
      info "Автозапуск:  $(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    fi
  else
    warn "Сервіс не встановлено"
  fi

  step "Режим оновлення"
  info "$REFRESH_MODE (опитування Google: $([[ "$EFF_POLL" == "0" ]] && echo вимкнено || echo "кожні $EFF_POLL"))"

  step "Монтування"
  if is_stale; then
    warn "Точка $MNT «зависла» (rclone не працює). Виправити: fusermount3 -uz \"$MNT\""
  elif is_mounted; then ok "Змонтовано: $MNT"
  else warn "Не змонтовано: $MNT"; fi

  step "Кеш"
  if [[ -d "$CACHE_DIR" ]]; then
    info "$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1) у $CACHE_DIR (ліміт $CACHE_SIZE, зберігання до $CACHE_AGE)"
  else
    info "Кешу немає"
  fi

  step "Вивантаження"
  local pending; pending="$(pending_uploads)"
  if [[ "${pending:-0}" -gt 0 ]]; then
    warn "Чекає вивантаження файлів: $pending (вивантажуються через $WRITE_BACK після закриття/збереження)"
    info "Не вимикайте комп'ютер і не запускайте switch-account/uninstall, доки це не стане 0."
  else
    ok "Усе вивантажено (черга порожня)"
  fi
  info "Файли, які зараз відкриті в програмі, потрапляють у чергу лише після закриття або збереження."
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
cmd_uninstall() {
  echo "${C_BOLD}$(_ "Видалення налаштувань Google Drive")${C_RESET}"
  echo
  info "Буде виконано:"
  info " • зупинено й вимкнено сервіс $SERVICE_NAME"
  info " • розмонтовано $MNT"
  info " • видалено файл сервісу $UNIT_FILE"
  info " • видалено автозапуск за мережею (якщо є)"
  info " • видалено команду gdmount та збережені налаштування"
  info " • видалено кеш $CACHE_DIR"
  info " • прибрано теку $MNT (лише якщо порожня)"
  info " • окремо запитаю про remote «$REMOTE» і пакет rclone"
  info "Файли на самому Google Drive НЕ видаляються."
  echo
  ask "Продовжити?" || { info "Скасовано."; exit 0; }

  wait_for_uploads || warn "Невивантажені файли лишаться в кеші, якщо ви не підтвердите їх видалення."

  step "1/6 Зупинка сервісу"
  if [[ -f "$WATCH_UNIT_FILE" ]]; then
    systemctl --user disable --now "$WATCH_SERVICE" >/dev/null 2>&1 || true
    ok "Спостерігача за мережею зупинено й вимкнено"
  fi
  if systemctl --user list-unit-files "$SERVICE_NAME" 2>/dev/null | grep -q "$SERVICE_NAME"; then
    systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    ok "Сервіс зупинено й вимкнено"
  else
    info "Сервіс не знайдено, пропускаю"
  fi

  step "2/6 Розмонтування"
  if is_mounted; then
    do_unmount && ok "Розмонтовано $MNT" || warn "Не вдалося розмонтувати $MNT (можливо, файли відкриті в програмах)"
  else
    info "Не змонтовано, пропускаю"
  fi

  step "3/6 Файл сервісу"
  if [[ -f "$WATCH_UNIT_FILE" || -f "$WATCH_SCRIPT" ]]; then
    rm -f "$WATCH_UNIT_FILE" "$WATCH_SCRIPT"
    systemctl --user daemon-reload
    systemctl --user reset-failed "$WATCH_SERVICE" >/dev/null 2>&1 || true
    ok "Видалено автозапуск за мережею"
  fi
  if [[ -f "$UNIT_FILE" ]]; then
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload
    systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    ok "Видалено $UNIT_FILE"
  else
    info "Файлу немає, пропускаю"
  fi

  step "4/6 Кеш"
  if [[ -d "$CACHE_DIR" ]]; then
    if confirm_cache_removal; then
      freed="$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
      rm -rf "$CACHE_DIR"
      ok "Видалено кеш ($freed)"
    else
      warn "Кеш залишено: $CACHE_DIR. Сервісу вже немає, тож самі файли не вивантажаться."
      warn "Невивантажені файли лежать у $CACHE_DIR/vfs/${REMOTE}/ : скопіюйте їх звідти вручну."
    fi
  else
    info "Кешу немає, пропускаю"
  fi

  step "5/6 Тека монтування"
  if [[ -d "$MNT" ]] && ! is_mounted; then
    if rmdir "$MNT" 2>/dev/null; then
      ok "Видалено порожню теку $MNT"
    else
      warn "$MNT не порожня, залишаю без змін"
    fi
  else
    info "Нічого видаляти"
  fi

  step "6/6 Remote та пакет"
  # Is there a record of what this script created? If the state file is absent,
  # ownership is unknown (for example, configured by an older script version).
  local known=0 remote_kept=0 pkg_kept=0
  [[ -f "$STATE_FILE" ]] && known=1

  if command -v rclone >/dev/null && rclone listremotes | grep -qx "${REMOTE}:"; then
    if [[ $known -eq 1 ]] && ! state_is REMOTE_CREATED; then
      info "Remote «$REMOTE» існував до цього скрипта, не чіпаю."
    else
      [[ $known -eq 0 ]] && warn "Немає запису, хто створив remote «$REMOTE» (можливо, стара версія скрипта)."
      if [[ $known -eq 0 && $ASSUME_YES -eq 1 ]]; then
        warn "З --yes remote невідомого походження не видаляю. Видаліть вручну: rclone config delete $REMOTE"
      elif ask "Видалити remote «$REMOTE» (токен доступу з rclone.conf)?"; then
        rclone config delete "$REMOTE"
        ok "Remote видалено"
        info "Щоб повністю відкликати доступ, зайдіть на https://myaccount.google.com/permissions"
      else
        info "Remote залишено (видалити пізніше: rclone config delete $REMOTE)"
        state_is REMOTE_CREATED && remote_kept=1
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
        pkg_remove rclone && ok "Пакет rclone видалено" || true
        info "Пакет fuse3 залишено, бо його можуть використовувати інші програми."
      else
        info "Пакет залишено"
        state_is PKG_INSTALLED && pkg_kept=1
      fi
    fi
  fi

  rm -f "$RC_ENV" "$CONF_FILE"
  # Remove the state file only if nothing remains for the next uninstall
  if [[ $remote_kept -eq 0 && $pkg_kept -eq 0 ]]; then
    rm -rf "$STATE_DIR"
  else
    info "Запис стану збережено, щоб наступний uninstall знову запитав про залишене."
  fi
  echo
  echo "${C_BOLD}${C_GREEN}$(_ "Готово.")${C_RESET} $(_ "Усе, що створив скрипт, прибрано.")"
  # Remove the installed command last (the script itself may be running from it)
  rm -f "$CLI_PATH"
  rm -f "$I18N_PATH"
  rmdir "$I18N_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# switch-account
# ---------------------------------------------------------------------------
cmd_switch_account() {
  [[ $EUID -ne 0 ]] || die "Не запускайте від root."
  command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: $0 install"
  rclone listremotes | grep -qx "${REMOTE}:" \
    || die "Remote «$REMOTE» не знайдено. Спершу виконайте: $0 install"

  have_network || die "Для зміни акаунту потрібен інтернет. Підключіться до мережі й повторіть."
  echo "${C_BOLD}$(_ "Зміна акаунту Google Drive")${C_RESET}"
  local old_account new_account was_active=0 watch_active=0
  old_account="$(current_account)"
  info "Remote:          $REMOTE"
  info "Поточний акаунт: ${old_account:-не вдалося визначити}"
  echo
  info "Буде виконано:"
  info " • зупинено сервіс і розмонтовано $MNT"
  info " • очищено кеш (він належить старому акаунту)"
  info " • повторну авторизацію в браузері"
  info " • запуск сервісу вже з новим акаунтом"
  info "Файли на Google Drive обох акаунтів не змінюються."
  echo
  ask "Продовжити?" || { info "Скасовано."; exit 0; }

  # The cache belongs to the old account; unsent files cannot be uploaded under the new account
  if ! wait_for_uploads; then
    die "Не всі файли вивантажено на Google Drive. Зачекайте (gdmount status) і повторіть."
  fi

  step "1/4 Зупинка сервісу"
  # Also stop the network watcher so it cannot restart the drive during the switch
  if systemctl --user is-active --quiet "$WATCH_SERVICE" 2>/dev/null; then
    watch_active=1
    systemctl --user stop "$WATCH_SERVICE"
  fi
  if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    was_active=1
    systemctl --user stop "$SERVICE_NAME"
    ok "Сервіс зупинено"
  else
    info "Сервіс не працював"
  fi
  if is_mounted; then
    if do_unmount; then
      ok "Розмонтовано $MNT"
    else
      restore_services
      die "Не вдалося розмонтувати $MNT. Закрийте програми, що використовують диск, і повторіть."
    fi
  fi

  step "2/4 Очищення кешу старого акаунту"
  if [[ -d "$CACHE_DIR" ]]; then
    if confirm_cache_removal; then
      rm -rf "$CACHE_DIR"
      ok "Кеш видалено"
    else
      restore_services
      die "Скасовано: кеш містить невивантажені файли ($CACHE_DIR/vfs/). Нічого не видалено."
    fi
  else
    info "Кешу немає"
  fi

  step "3/4 Авторизація нового акаунту"
  info "Зараз відкриється браузер."
  warn "Google може автоматично підставити СТАРИЙ акаунт. Оберіть «Використати інший"
  warn "акаунт» або скопіюйте посилання з термінала в приватне вікно браузера."
  info "Якщо rclone спитає про auto config, відповідайте y (Yes)."
  echo
  if ! rclone config reconnect "${REMOTE}:"; then
    err "Авторизація не вдалася, ймовірно, лишився попередній акаунт."
    restore_services
    exit 1
  fi
  if ! rclone lsd "${REMOTE}:" --max-depth 1 >/dev/null 2>&1; then
    restore_services
    die "Не вдалося отримати доступ до диска з новим токеном. Спробуйте ще раз."
  fi
  new_account="$(current_account)"
  ok "Авторизовано акаунт: ${new_account:-не вдалося визначити}"
  if [[ -n "$old_account" && "$old_account" == "$new_account" ]]; then
    warn "Це той самий акаунт, що й раніше. Щоб обрати інший, запустіть команду ще раз"
    warn "і в браузері виберіть інший акаунт Google."
  fi

  step "4/4 Запуск сервісу"
  if [[ -f "$UNIT_FILE" ]]; then
    systemctl --user start "$SERVICE_NAME"
    [[ $watch_active -eq 1 ]] && systemctl --user start "$WATCH_SERVICE" || true
    for _ in $(seq 1 30); do
      is_mounted && break
      sleep 1
    done
    if is_mounted; then
      ok "Диск змонтовано в $MNT"
    else
      err "Монтування не з'явилося за 30 с. Логи: journalctl --user -u $SERVICE_NAME -n 50"
      exit 1
    fi
  else
    warn "Сервіс не встановлено. Виконайте: $0 install"
  fi

  echo
  echo "${C_BOLD}${C_GREEN}$(_ "Готово.")${C_RESET} $(_ "Старий акаунт:") ${old_account:-?}  →  $(_ "новий:") ${new_account:-?}"
  info "Щоб повністю відкликати доступ старого акаунту, зайдіть під ним на"
  info "https://myaccount.google.com/permissions і видаліть доступ для rclone."
}

# ---------------------------------------------------------------------------
# refresh / start / stop
# ---------------------------------------------------------------------------
cmd_refresh() {
  command -v rclone >/dev/null || die "rclone не встановлено. Спершу виконайте: gdmount install"
  { systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null && is_mounted; } \
    || die "Диск зараз не змонтовано (немає мережі чи сервіс зупинено). Дивіться: gdmount status"
  have_network || die "Немає інтернету. Оновлення без мережі лише зітре збережені списки тек."

  echo "${C_BOLD}$(_ "Оновлення списків файлів")${C_RESET}"
  if [[ $REFRESH_ALL -eq 1 ]]; then
    info "Читаю весь диск (метадані тек, не вміст файлів). На великому диску це може тривати хвилини..."
    rc_run vfs/refresh recursive=true
    ok "Усі теки перечитано."
  elif [[ -n "$REFRESH_PATH" ]]; then
    local rel="${REFRESH_PATH#"$MNT"}"
    rel="${rel#/}"; rel="${rel%/}"; [[ "$rel" == "." ]] && rel=""
    local args=(vfs/refresh "dir=$rel")
    [[ $RECURSIVE -eq 1 ]] && args+=(recursive=true)
    info "Перечитую «${rel:-корінь диска}»$([[ $RECURSIVE -eq 1 ]] && echo " разом із підтеками")..."
    rc_run "${args[@]}"
    ok "Готово."
  else
    rc_run vfs/forget
    ok "Кеш списків тек очищено. Свіжі дані підтягнуться, коли ви відкриєте теки."
    info "Відкриті вікна файлового менеджера оновіть (F5)."
  fi
}

cmd_mode() {
  if [[ -z "$MODE_ARG" ]]; then
    local poll_status
    [[ "$EFF_POLL" == "0" ]] && poll_status="$(_ "вимкнено")" || poll_status="$(_ "кожні") $EFF_POLL"
    echo "$(_ "Режим оновлення"): ${C_BOLD}$REFRESH_MODE${C_RESET} ($(_ "опитування Google:") $poll_status)"
    info "$(_ "Змінити:") gdmount mode manual | gdmount mode auto"
    return 0
  fi
  case "$MODE_ARG" in
    manual|auto) ;;
    *) die "Невідомий режим «$MODE_ARG». Доступні: manual, auto" ;;
  esac
  [[ -f "$UNIT_FILE" ]] || die "Сервіс не встановлено. Виконайте: gdmount install --refresh-mode $MODE_ARG"
  if [[ "$MODE_ARG" == "$REFRESH_MODE" ]]; then
    info "Режим уже $REFRESH_MODE, нічого міняти."
    return 0
  fi
  REFRESH_MODE="$MODE_ARG"
  # Changing the mode resets previously set intervals (otherwise manual would not stay manual);
  # a fresh --poll-interval in the same command is preserved
  [[ $POLL_FROM_FLAG -eq 1 ]] || POLL_INTERVAL=""
  DIR_CACHE_TIME=""
  resolve_mode
  info "Перемикаю на режим $REFRESH_MODE (опитування Google: $([[ "$EFF_POLL" == "0" ]] && echo вимкнено || echo "кожні $EFF_POLL"))."
  info "Сервіс буде перезапущено, диск на кілька секунд розмонтується."
  ask "Продовжити?" || { info "Скасовано."; exit 0; }
  cmd_install
}

cmd_stop() {
  systemctl --user stop "$WATCH_SERVICE" >/dev/null 2>&1 || true
  systemctl --user stop "$SERVICE_NAME"  >/dev/null 2>&1 || true
  ok "Диск і автозапуск за мережею зупинено. Запустити знову: gdmount start"
}

cmd_start() {
  [[ -f "$UNIT_FILE" ]] || die "Сервіс не встановлено. Виконайте: gdmount install"
  if [[ -f "$WATCH_UNIT_FILE" ]]; then
    systemctl --user start "$WATCH_SERVICE"
    if have_network; then ok "Запущено, диск змонтується за кілька секунд."
    else ok "Запущено, диск змонтується, щойно з'явиться мережа."; fi
  else
    systemctl --user start "$SERVICE_NAME"
    ok "Запущено."
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || usage
COMMAND="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)     REMOTE="${2:?$(_ "Потрібне значення для --remote")}"; shift 2 ;;
    --mount)      MNT="${2:?$(_ "Потрібне значення для --mount")}"; shift 2 ;;
    --cache-size) CACHE_SIZE="${2:?$(_ "Потрібне значення для --cache-size")}"; shift 2 ;;
    --cache-age)  CACHE_AGE="${2:?$(_ "Потрібне значення для --cache-age")}"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="${2:?$(_ "Потрібне значення для --poll-interval")}"; POLL_FROM_FLAG=1; shift 2 ;;
    --write-back) WRITE_BACK="${2:?$(_ "Потрібне значення для --write-back")}"; shift 2 ;;
    --refresh-mode) REFRESH_MODE="${2:?$(_ "Потрібне значення для --refresh-mode")}"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -r|--recursive) RECURSIVE=1; shift ;;
    --all)        REFRESH_ALL=1; shift ;;
    -h|--help)    usage ;;
    -*)           die "Невідома опція: $1 (див. --help)" ;;
    *)            if [[ "$COMMAND" == "refresh" && -z "$REFRESH_PATH" ]]; then
                    REFRESH_PATH="$1"; shift
                  elif [[ "$COMMAND" == "mode" && -z "$MODE_ARG" ]]; then
                    MODE_ARG="$1"; shift
                  else
                    die "Зайвий аргумент: $1 (див. --help)"
                  fi ;;
  esac
done

resolve_mode

case "$COMMAND" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  refresh)   cmd_refresh ;;
  mode)      cmd_mode ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  switch-account|switch) cmd_switch_account ;;
  uninstall) cmd_uninstall ;;
  -h|--help|help) usage ;;
  *)         die "Невідома команда: $COMMAND (доступні: install, refresh, mode, status, start, stop, switch-account, uninstall)" ;;
esac
