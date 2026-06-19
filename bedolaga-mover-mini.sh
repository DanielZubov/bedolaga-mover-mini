#!/bin/bash
# =============================================================
#  bedolaga-mover — инструмент переноса Bedolaga стека (Очищенный)
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ARCHIVE="/root/bedolaga_migration.tar.gz"

log()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

header() {
  clear
  echo ""
  echo -e "${CYAN}${BOLD}  ██████╗ ███████╗██████╗  ██████╗ ██╗      █████╗  ██████╗  █████╗ ${NC}"
  echo -e "${BLUE}${BOLD}                   M O V E R  —  мини-версия${NC}"
  echo -e "  ${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo ""
}

_find_by_container() {
  local container="$1"
  command -v docker &>/dev/null || return 1
  docker inspect "$container" 2>/dev/null \
    | grep '"Source"' \
    | awk -F'"' '{print $4}' \
    | grep -v '/var/lib/docker' \
    | head -1 \
    | xargs -I{} dirname {} 2>/dev/null || return 1
}

_find_by_paths() {
  local -a candidates=("$@")
  for p in "${candidates[@]}"; do
    for expanded in $p; do
      [ -f "$expanded/docker-compose.yml" ] && echo "$expanded" && return 0
    done
  done
  return 1
}

find_bot_dir() {
  [ -n "$BOT_DIR" ] && { echo "$BOT_DIR"; return; }
  local found
  for cname in remnawave_bot bedolaga_bot; do
    found=$(_find_by_container "$cname" 2>/dev/null) && [ -n "$found" ] && { echo "$found"; return; }
  done
  found=$(_find_by_paths /root/bedolaga-telegram-bot /opt/bedolaga-telegram-bot) && [ -n "$found" ] && { echo "$found"; return; }
  
  read -rp "  Укажи путь к боту вручную: " manual
  echo "$manual"
}

find_cabinet_dir() {
  [ -n "$CABINET_DIR" ] && { echo "$CABINET_DIR"; return; }
  local found
  for cname in cabinet_frontend bedolaga_cabinet; do
    found=$(_find_by_container "$cname" 2>/dev/null) && [ -n "$found" ] && { echo "$found"; return; }
  done
  return 1
}

# =============================================================
# PACK
# =============================================================
cmd_pack() {
  header
  log "Ищем компоненты..."
  BOT_DIR=$(find_bot_dir)
  CABINET_DIR=$(find_cabinet_dir)

  WORK_DIR=$(mktemp -d)
  trap "rm -rf '$WORK_DIR'" EXIT

  log "Останавливаем бота..."
  cd "$BOT_DIR" && docker compose stop bot

  log "Снимаем дамп БД..."
  source <(grep -E "^POSTGRES_(USER|DB)" "$BOT_DIR/.env" 2>/dev/null || true)
  docker compose exec -T postgres pg_dump -Fc -U "${POSTGRES_USER:-remnawave_user}" "${POSTGRES_DB:-remnawave_bot}" > "$WORK_DIR/bot_db.dump"

  cp "$BOT_DIR/.env" "$WORK_DIR/bot.env"
  [ -d "$BOT_DIR/uploads" ] && cp -r "$BOT_DIR/uploads" "$WORK_DIR/bot_uploads"
  [ -f "$CABINET_DIR/.env" ] && cp "$CABINET_DIR/.env" "$WORK_DIR/cabinet.env"

  tar -czf "$ARCHIVE" -C "$WORK_DIR" .
  ok "Архив создан: $ARCHIVE"
}

# =============================================================
# UNPACK
# =============================================================
cmd_unpack() {
  header
  [ -f "$ARCHIVE" ] || fail "Архив не найден"
  
  BOT_DIR="/opt/remnawave-bedolaga-telegram-bot"
  CABINET_DIR="/srv/cabinet"
  
  WORK_DIR=$(mktemp -d)
  tar -xzf "$ARCHIVE" -C "$WORK_DIR"

  log "Разворачиваем бота..."
  mkdir -p "$BOT_DIR"
  cp "$WORK_DIR/bot.env" "$BOT_DIR/.env"
  [ -d "$WORK_DIR/bot_uploads" ] && cp -r "$WORK_DIR/bot_uploads" "$BOT_DIR/uploads"

  cd "$BOT_DIR"
  docker compose up -d postgres redis
  sleep 10
  docker compose exec -T postgres pg_restore -U "${POSTGRES_USER:-remnawave_user}" -d "${POSTGRES_DB:-remnawave_bot}" --clean < "$WORK_DIR/bot_db.dump"
  docker compose up -d

  if [ -f "$WORK_DIR/cabinet.env" ]; then
    log "Разворачиваем Cabinet..."
    mkdir -p "$CABINET_DIR"
    cp "$WORK_DIR/cabinet.env" "$CABINET_DIR/.env"
    # Тут будет ваш docker-compose.yml для кабинета
    cd "$CABINET_DIR" && docker compose up -d
  fi
  ok "Готово!"
}

main_menu() {
  while true; do
    header
    echo "1) Упаковать | 2) Распаковать | 0) Выход"
    read -rp "  Выбор: " choice
    case "$choice" in
      1) cmd_pack ;;
      2) cmd_unpack ;;
      0) exit 0 ;;
    esac
  done
}

main_menu
