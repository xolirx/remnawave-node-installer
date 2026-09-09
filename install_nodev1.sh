#!/bin/bash
# Установка ноды Remnawave через API (без лишнего дизайна)

if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запустите скрипт через sudo -i"
    exit 1
fi

# Запрашиваем данные
read -p "URL панели (https://panel.domain.com): " PANEL_URL
read -sp "API-ключ: " API_KEY
echo
read -p "Имя ноды (Enter для авто): " NODE_NAME
[ -z "$NODE_NAME" ] && NODE_NAME="Node-$(hostname)"
read -p "Порт ноды (по умолчанию 2222): " NODE_PORT
[ -z "$NODE_PORT" ] && NODE_PORT="2222"

# IP сервера
SERVER_IP=$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo "IP сервера: $SERVER_IP"

# Проверяем API
echo "Проверка API..."
HTTP_CODE=$(curl -s -o /tmp/api_nodes -w "%{http_code}" -X GET "$PANEL_URL/api/nodes" \
    -H "x-api-key: $API_KEY" -H "Content-Type: application/json")
if [ "$HTTP_CODE" != "200" ]; then
    echo "Ошибка: неверный URL или API-ключ (код $HTTP_CODE)"
    exit 1
fi
echo "API-ключ валидный"

# Ищем или создаём ноду
NODE_ID=$(grep -o "\"id\":\"[^\"]*\",\"name\":\"$NODE_NAME\"" /tmp/api_nodes | head -1 | sed 's/.*"id":"\([^"]*\)".*/\1/')
if [ -z "$NODE_ID" ]; then
    echo "Создаём ноду..."
    CREATE_DATA="{\"name\":\"$NODE_NAME\",\"ip\":\"$SERVER_IP\",\"port\":$NODE_PORT}"
    curl -s -X POST "$PANEL_URL/api/nodes" \
        -H "x-api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$CREATE_DATA" > /tmp/node_create
    NODE_ID=$(grep -o "\"id\":\"[^\"]*\"" /tmp/node_create | head -1 | sed 's/.*"id":"\([^"]*\)".*/\1/')
    if [ -z "$NODE_ID" ]; then
        echo "Ошибка создания ноды"
        exit 1
    fi
    echo "Нода создана, ID: $NODE_ID"
else
    echo "Нода уже существует, ID: $NODE_ID"
fi

# Получаем конфиг ноды
echo "Получаем конфиг..."
curl -s -X GET "$PANEL_URL/api/nodes/$NODE_ID/docker-compose" \
    -H "x-api-key: $API_KEY" > /tmp/node_compose

# Устанавливаем Docker (если нет)
if ! command -v docker &>/dev/null; then
    echo "Устанавливаем Docker..."
    apt update -qq && apt install -y -qq docker.io docker-compose-plugin
    systemctl enable --now docker &>/dev/null
fi

# Запускаем ноду
NODE_DIR="/opt/remnanode"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"
cp /tmp/node_compose docker-compose.yml

# Если в конфиге нет порта — добавляем
if ! grep -q "APP_PORT" docker-compose.yml 2>/dev/null; then
    echo "APP_PORT=$NODE_PORT" > .env
fi

echo "Запускаем ноду..."
docker compose up -d

echo "Готово. Проверка: docker ps | grep remnanode"
