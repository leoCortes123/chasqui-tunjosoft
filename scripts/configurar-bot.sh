#!/usr/bin/env bash
# =====================================================================
# Chasqui TunjoSoft — configurar-bot.sh
# Registra el webhook de Telegram contra n8n, fija los comandos del bot
# y muestra el enlace del QR de la sala de espera.
#
# Uso:   bash scripts/configurar-bot.sh
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

: "${TELEGRAM_BOT_TOKEN:?Falta TELEGRAM_BOT_TOKEN en .env}"

# La URL pública la manda el registrador, que es el único que sabe cómo se llama
# el túnel hoy y la deja escrita en config.portal_url. Este script la lee de ahí
# y sólo cae en WEBHOOK_URL del .env si la base no está arriba: con el túnel
# levantado, re-registrar desde un .env viejo dejaría el bot apuntando a una
# dirección muerta hasta el siguiente reinicio del túnel.
publica=$(docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
          "SELECT valor FROM config WHERE clave = 'portal_url'" 2>/dev/null \
          | tr -d '[:space:]' || true)

case "$publica" in
  https://*) WEBHOOK_URL="$publica" ;;
  *)         publica='' ;;
esac

: "${WEBHOOK_URL:?Falta WEBHOOK_URL en .env}"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
RUTA_WEBHOOK="${WEBHOOK_URL%/}/webhook/chasqui-tunjosoft-telegram"

echo "==> Verificando el token del bot"
respuesta=$(curl -sS "${API}/getMe")
if ! echo "$respuesta" | grep -q '"ok":true'; then
  echo "El token no es válido. Respuesta de Telegram:" >&2
  echo "$respuesta" >&2
  exit 1
fi
usuario_bot=$(echo "$respuesta" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
echo "    Bot: @${usuario_bot}"

# Telegram exige HTTPS para los webhooks. En una demo local, WEBHOOK_URL suele
# ser http://localhost, que Telegram rechaza. En ese caso el bot funciona por
# sondeo (polling) desde n8n, o se expone n8n con un túnel (cloudflared, ngrok).
case "$RUTA_WEBHOOK" in
  https://*)
    echo "==> Registrando el webhook"
    echo "    ${RUTA_WEBHOOK}"
    curl -sS -X POST "${API}/setWebhook" \
      -d "url=${RUTA_WEBHOOK}" \
      -d "allowed_updates=[\"message\",\"callback_query\"]" \
      -d "drop_pending_updates=true" | sed 's/^/    /'
    echo
    ;;
  *)
    echo "==> AVISO: WEBHOOK_URL no es HTTPS (${RUTA_WEBHOOK})."
    echo "    Telegram sólo acepta webhooks HTTPS. Para la demo local, expón n8n"
    echo "    con un túnel y vuelve a ejecutar este script, por ejemplo:"
    echo "        cloudflared tunnel --url http://localhost:5678"
    echo "    Luego pon esa URL https en WEBHOOK_URL dentro de .env."
    ;;
esac

echo "==> Configurando los comandos del bot"
curl -sS -X POST "${API}/setMyCommands" \
  -H 'Content-Type: application/json' \
  -d '{"commands":[
        {"command":"start","description":"Empezar"},
        {"command":"portal","description":"Enlace para entrar al portal"},
        {"command":"ayuda","description":"Ayuda"}
      ]}' | sed 's/^/    /'
echo

# La descripción es lo que Telegram muestra en la pantalla previa a /start
# ("¿Qué puede hacer este bot?"). Al revés que en el bot de un cliente, este
# SÍ se explica: es el demo comercial y quien lo abre llegó por un enlace
# nuestro, no por casualidad.
echo "==> Descripción pública del bot"
curl -sS -X POST "${API}/setMyDescription" \
  --data-urlencode "description=Asistente de TunjoSoft. Pregúntale qué hacemos, cuánto vale y agenda una reunión. Si prefieres hablar con una persona, escribe ASESOR." \
  | sed 's/^/    /'
curl -sS -X POST "${API}/setMyShortDescription" \
  --data-urlencode "short_description=El asistente de TunjoSoft: responde, cotiza y agenda." \
  | sed 's/^/    /'
echo

echo "==> Enlaces"
echo "    Chat con el bot:  https://t.me/${usuario_bot}"
echo "    Portal local:     ${WEB_PUBLIC_URL:-http://localhost:3300}/entrar"

if [ -n "$publica" ]; then
  echo
  echo "==> Dirección pública en uso (la escribió el registrador)"
  echo "    Portal: ${publica}/entrar"
fi
echo
echo "El enlace del chat es el que se le manda a un prospecto: que use el"
echo "asistente para agendar la reunión en la que se le va a vender el"
echo "asistente es toda la demostración."
