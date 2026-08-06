#!/usr/bin/env bash
# =====================================================================
# Chasqui TunjoSoft — probar-chat.sh
# Conversa con el asistente por el canal `simulador`, desde la terminal.
#
#   scripts/probar-chat.sh "hola, a que hora abren?"
#   scripts/probar-chat.sh "mi perro convulsiona" 3001234567
#
# El segundo argumento es el celular del contacto: con el mismo número, la
# conversación continúa; con uno distinto, empieza de cero. Es la forma de
# probar un hilo largo o de arrancar limpio sin borrar nada.
#
# No sale a internet ni gasta un mensaje de WhatsApp: entra por la misma
# puerta que el canal real (`asistente_recibir`), así que lo que se ve aquí
# es lo que vería un cliente.
# =====================================================================
set -euo pipefail

TEXTO="${1:-}"
CELULAR="${2:-3001234567}"
CONTENEDOR="${CONTENEDOR_DB:-chasqui-tunjosoft-db}"
ESPERA_MAX="${ESPERA_MAX:-90}"   # segundos

if [ -z "$TEXTO" ]; then
  echo "uso: scripts/probar-chat.sh \"tu mensaje\" [celular]" >&2
  exit 1
fi

q() {
  docker exec "$CONTENEDOR" psql -U chasqui_tunjosoft -d chasqui_tunjosoft \
    -X -q -tAc "$1"
}

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTENEDOR"; then
  echo "El contenedor $CONTENEDOR no está corriendo. Levanta con: docker compose --profile local up -d" >&2
  exit 1
fi

CONV=$(q "SELECT (conversacion_entrante('simulador', \$\$$CELULAR\$\$, 'Tutor de prueba', \$\$sim-$CELULAR\$\$))->>'conversacion_id'")
ANTES=$(q "SELECT count(*) FROM mensaje WHERE conversacion_id = '$CONV' AND direccion = 'saliente'")
ID_EXTERNO="sim-$(date +%s%N)"

MOTIVO=$(q "SELECT COALESCE((asistente_recibir('$CONV', \$\$$TEXTO\$\$, '$ID_EXTERNO'))->>'motivo', 'al modelo')")

printf '\n\033[1m› tú:\033[0m %s\n' "$TEXTO"

# El texto de una urgencia y el de «asesor» los arma la base y los manda la
# cola; la respuesta del modelo tarda lo que tarde la API. En los dos casos
# lo que se espera es lo mismo: que aparezca un mensaje saliente nuevo.
for _ in $(seq 1 $((ESPERA_MAX / 2))); do
  AHORA=$(q "SELECT count(*) FROM mensaje WHERE conversacion_id = '$CONV' AND direccion = 'saliente'")
  [ "$AHORA" -gt "$ANTES" ] && break
  sleep 2
done

if [ "${AHORA:-0}" -le "$ANTES" ]; then
  printf '\033[33m(sin respuesta en %ss — mira: docker compose logs worker)\033[0m\n' "$ESPERA_MAX"
else
  printf '\033[1m› bot:\033[0m '
  q "SELECT texto FROM mensaje WHERE conversacion_id = '$CONV' AND direccion = 'saliente' ORDER BY id DESC LIMIT 1"
fi

ESTADO=$(q "SELECT CASE WHEN atendida_por_humano
                        THEN 'SÍ · ' || COALESCE(motivo_escalamiento, '—')
                        ELSE 'no' END
              FROM conversacion WHERE id = '$CONV'")

printf '\n\033[2m  ruta: %s   |   escalada a humano: %s\033[0m\n\n' "$MOTIVO" "$ESTADO"
