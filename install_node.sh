#!/bin/bash

# ============================================================
# УСТАНОВЩИК НОДЫ REMNAWAVE (ЧЕРЕЗ API)
# Минималистичный и проверенный
# ============================================================

set -e

# Цвета (без смайликов)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1" >&2; }

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    err "Запусти скрипт через sudo -i"
    exit 1
fi

clear

# Баннер
echo -e "${BLUE}  
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   ███╗   ██╗ ██████╗ ██████╗ ███████╗                  ║
║   ████╗  ██║██╔═══██╗██╔══██╗██╔════╝                  ║
║   ██╔██╗ ██║██║   ██║██║  ██║█████╗                    ║
║   ██║╚██╗██║██║   ██║██║  ██║██╔══╝                    ║
║   ██║ ╚████║╚██████╔╝██████╔╝███████╗                  ║
║   ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝                  ║
║                                                          ║
║             УСТАНОВЩИК НОДЫ REMNAWAVE                   ║
║                   API  v2.0                             ║
╚══════════════════════════════════════════════════════════╝${NC}"

# ============================================
# ВВОД ДАННЫХ
# ============================================

read -p "$(echo -e ${YELLOW}Введите URL панели (пример: https://panel.domain.com): ${NC})" PANEL_URL
PANEL_URL=$(echo "$PANEL_URL" | sed 's:/*$::')
if [[ ! "$PANEL_URL" =~ ^https?:// ]]; then
    err "URL должен начинаться с http:// или https://"
    exit 1
fi

read -sp "$(echo -e ${YELLOW}Введите API-ключ: ${NC})" API_KEY
echo
if [ ${#API_KEY} -lt 10 ]; then
    err "API-ключ слишком короткий"
    exit 1
fi

read -p "$(echo -e ${YELLOW}Имя ноды (оставьте пустым для авто-имени): ${NC})" NODE_NAME
[ -z "$NODE_NAME" ] && NODE_NAME="Node-$(hostname)"

# Порт ноды
while true; do
    read -p "$(echo -e ${YELLOW}Порт ноды (по умолчанию 2222): ${NC})" NODE_PORT
    [ -z "$NODE_PORT" ] && NODE_PORT="2222"
    if [[ "$NODE_PORT" =~ ^[0-9]+$ ]] && [ "$NODE_PORT" -ge 1 ] && [ "$NODE_PORT" -le 65535 ]; then
        break
    else
        warn "Введите число от 1 до 65535"
    fi
done

# IP сервера
SERVER_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo -e "${BLUE}[*] IP сервера: ${SERVER_IP}${NC}"

# ============================================
# ПРОВЕРКА API
# ============================================

info "Проверка подключения к панели..."

# Пробуем получить список нод для проверки токена
HTTP_RESPONSE=$(curl -s -o /tmp/api_response -w "%{http_code}" -X GET "$PANEL_URL/api/nodes" \
    -H "x-api-key: $API_KEY" \
    -H "Content-Type: application/json")

if [ "$HTTP_RESPONSE" = "200" ]; then
    ok "API-ключ валидный"
else
    err "Ошибка API (код $HTTP_RESPONSE). Проверьте URL и API-ключ."
    cat /tmp/api_response 2>/dev/null
    exit 1
fi

# ============================================
# ПОИСК/СОЗДАНИЕ НОДЫ
# ============================================

info "Поиск ноды '$NODE_NAME'..."

# Ищем существующую ноду по имени
NODE_ID=$(grep -o "\"id\":\"[^\"]*\",\"name\":\"$NODE_NAME\"" /tmp/api_response 2>/dev/null | head -1 | sed 's/.*"id":"\([^"]*\)".*/\1/')

if [ -n "$NODE_ID" ]; then
    ok "Нода уже существует (ID: $NODE_ID)"
else
    info "Создание новой ноды..."
    CREATE_DATA="{\"name\":\"$NODE_NAME\",\"ip\":\"$SERVER_IP\",\"port\":$NODE_PORT}"
    curl -s -X POST "$PANEL_URL/api/nodes" \
        -H "x-api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$CREATE_DATA" > /tmp/node_create
    
    if grep -q "id" /tmp/node_create; then
        NODE_ID=$(grep -o "\"id\":\"[^\"]*\"" /tmp/node_create | head -1 | sed 's/.*"id":"\([^"]*\)".*/\1/')
        ok "Нода создана (ID: $NODE_ID)"
    else
        err "Не удалось создать ноду:"
        cat /tmp/node_create
        exit 1
    fi
fi

# ============================================
# ПОЛУЧЕНИЕ КОНФИГА НОДЫ
# ============================================

info "Получение конфигурации ноды..."

curl -s -X GET "$PANEL_URL/api/nodes/$NODE_ID/docker-compose" \
    -H "x-api-key: $API_KEY" > /tmp/node_compose

if grep -q "version\|services" /tmp/node_compose 2>/dev/null; then
    ok "Конфигурация получена"
else
    err "Не удалось получить конфиг:"
    cat /tmp/node_compose
    exit 1
fi

# ============================================
# УСТАНОВКА DOCKER
# ============================================

if ! command -v docker &>/dev/null; then
    info "Установка Docker..."
    apt update -qq
    apt install -y -qq apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - &>/dev/null
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
    apt update -qq
    apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker &>/dev/null
    ok "Docker установлен"
else
    ok "Docker уже есть"
fi

# ============================================
# ЗАПУСК НОДЫ
# ============================================

NODE_DIR="/opt/remnanode"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"

# Сохраняем конфиг
cat /tmp/node_compose > docker-compose.yml

# Если в конфиге нет порта, добавляем через .env
if ! grep -q "APP_PORT" docker-compose.yml 2>/dev/null; then
    echo "APP_PORT=$NODE_PORT" > .env
    ok "Добавлен порт в .env"
fi

info "Запуск ноды..."
docker compose pull -q
docker compose up -d

sleep 3

if docker ps | grep -q remnanode; then
    ok "Нода запущена"
else
    warn "Нода не запустилась. Логи:"
    docker compose logs --tail=20
fi

# ============================================
# ИТОГОВАЯ ИНФОРМАЦИЯ
# ============================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  УСТАНОВКА ЗАВЕРШЕНА                                   ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  Имя:   $NODE_NAME                                     ║${NC}"
echo -e "${GREEN}║  ID:    $NODE_ID                                      ║${NC}"
echo -e "${GREEN}║  Порт:  $NODE_PORT                                     ║${NC}"
echo -e "${GREEN}║  Путь:  $NODE_DIR                                      ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║  Логи:  docker compose -f $NODE_DIR/docker-compose.yml logs -f${NC}"
echo -e "${GREEN}║  Статус: docker compose -f $NODE_DIR/docker-compose.yml ps${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

# Проверка открытых портов
echo ""
info "Проверка портов на сервере:"
ss -tulpn | grep -E ":$NODE_PORT |:3042[3-6] " | awk '{print $4}' | sort -u || warn "Нет активных портов из диапазона"
