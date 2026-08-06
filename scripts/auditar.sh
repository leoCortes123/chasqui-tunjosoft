#!/usr/bin/env bash
# =====================================================================
# Chasqui TunjoSoft — auditar.sh
# Audita la parte técnica de un sitio sobre el HTML crudo: idioma, meta,
# H1, imágenes sin alt, schema, palabras indexables y stack.
#
# Uso:
#   ./scripts/auditar.sh https://sitio1.com https://sitio2.com
#   ./scripts/auditar.sh --guardar https://sitio1.com      (además, a la base)
#
# Lo que mide es medición directa, no estimación: por eso es confiable y por
# eso se puede citar en una propuesta. Lo que NO mide —reseñas, posiciones—
# se levanta a mano y se verifica antes de citarlo.
#
# Sobre --guardar
# ---------------
# Guarda cada corrida en `auditoria_sitio`, fechada, y la engancha al
# prospecto si la URL coincide con la suya. Eso es lo que después permite
# comparar el antes y el después, que es la fase 4 del método: sin el «antes»
# archivado el día cero, el «después» no demuestra nada.
#
# El asistente interno lo lee con la herramienta `resultado_auditoria`.
# =====================================================================
set -uo pipefail

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36"
OUT=/tmp/audit_out
mkdir -p $OUT

GUARDAR=0
if [ "${1:-}" = "--guardar" ]; then
  GUARDAR=1
  shift
fi

if [ $# -eq 0 ]; then
  echo "Uso: $0 [--guardar] <url> [url...]" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
if [ "$GUARDAR" = "1" ]; then
  [ -f .env ] || { echo "No existe .env: no se puede guardar en la base." >&2; exit 1; }
  set -a; . ./.env; set +a
fi

for url in "$@"; do
  host=$(echo "$url" | sed -E 's#https?://##; s#/.*##')
  f="$OUT/$host.html"
  code=$(curl -sL --max-time 30 -A "$UA" -w '%{http_code}' "$url" -o "$f")
  size=$(wc -c < "$f" 2>/dev/null || echo 0)
  lang=$(grep -oim1 '<html[^>]*lang="[^"]*"' "$f" | grep -oi 'lang="[^"]*"' | head -1)
  oglocale=$(grep -oim1 'og:locale"[^>]*content="[^"]*"' "$f" | grep -o 'content="[^"]*"' | head -1)
  desc=$(grep -oicm1 'name="description"' "$f")
  h1=$(grep -oic '<h1' "$f")
  imgs=$(grep -oic '<img' "$f")
  altv=$(grep -oic 'alt=""' "$f")
  noalt=$(python3 - "$f" <<'PY'
import sys,re
h=open(sys.argv[1],encoding='utf8',errors='ignore').read()
tags=re.findall(r'<img\b[^>]*>',h,re.I)
sin=sum(1 for t in tags if not re.search(r'alt="[^"]+"',t,re.I))
print(f"{sin}/{len(tags)}")
PY
)
  types=$(grep -o '"@type": *"[^"]*"' "$f" | sed 's/.*"@type": *"//; s/"//' | sort -u | tr '\n' ',' )
  types2=$(grep -o '"@type":"[^"]*"' "$f" | sed 's/.*"@type":"//; s/"//' | sort -u | tr '\n' ',')
  wp=$(grep -oim1 'WordPress [0-9.]*' "$f" | head -1)
  elem=$(grep -oim1 'elementor[^"]*ver=[0-9.]*' "$f" | grep -o 'ver=[0-9.]*' | head -1)
  yoast=$(grep -oim1 'Yoast SEO v[0-9.]*' "$f" | head -1)
  wa=$(grep -oic 'wa.me\|api.whatsapp' "$f")
  words=$(python3 - "$f" <<'PY'
import sys,re
h=open(sys.argv[1],encoding='utf8',errors='ignore').read()
h=re.sub(r'(?is)<(script|style|noscript).*?</\1>',' ',h)
t=re.sub(r'(?s)<[^>]+>',' ',h)
t=re.sub(r'&[a-z#0-9]+;',' ',t)
print(len([w for w in t.split() if len(w)>1]))
PY
)
  echo "=== $host  [HTTP $code, ${size}B]"
  echo "    lang=${lang:-NINGUNO} | og:locale=${oglocale:-no} | meta-desc=$desc | H1=$h1 | palabras=$words"
  echo "    img sin alt: $noalt | alt vacio: $altv | whatsapp-links: $wa"
  echo "    schema: ${types}${types2}"
  echo "    stack: ${wp:-?} ${elem:+Elementor $elem} ${yoast:-}"

  [ "$GUARDAR" = "1" ] || continue

  # El puntaje es una regla simple y explícita, no una nota de examen: cinco
  # cosas que o están o no están. Sirve para ordenar prospectos y para ver si
  # una corrida posterior mejoró; no para presumirlo como métrica.
  puntaje=$(python3 - "$lang" "$desc" "$h1" "$words" "${types}${types2}" "$noalt" <<'PY'
import sys
lang, desc, h1, words, schema, noalt = sys.argv[1:7]
p = 0
if lang.strip():            p += 20
if desc.strip() not in ('', '0'): p += 20
if h1.strip() not in ('', '0'):   p += 20
if int(words or 0) >= 300:  p += 20
if schema.strip(','):       p += 10
try:
    sin, total = (int(x) for x in noalt.split('/'))
    if total == 0 or sin / total < 0.2: p += 10
except Exception:
    pass
print(p)
PY
)

  hallazgos=$(python3 - "$lang" "$oglocale" "$desc" "$h1" "$words" "$noalt" "$altv" "$wa" "${types}${types2}" "${wp:-}" "${elem:-}" "${yoast:-}" "$size" <<'PY'
import json, sys
(lang, oglocale, desc, h1, words, noalt, altv, wa, schema, wp, elem, yoast, size) = sys.argv[1:14]
print(json.dumps({
  "lang": lang or None,
  "og_locale": oglocale or None,
  "meta_descripcion": desc not in ('', '0'),
  "h1": int(h1 or 0),
  "palabras_indexables": int(words or 0),
  "img_sin_alt": noalt,
  "alt_vacio": int(altv or 0),
  "enlaces_whatsapp": int(wa or 0),
  "schema": [t for t in schema.split(',') if t],
  "stack": {"wordpress": wp or None, "elementor": elem or None, "yoast": yoast or None},
  "peso_bytes": int(size or 0),
}, ensure_ascii=False))
PY
)

  resumen="lang=${lang:-ninguno}; H1=$h1; palabras=$words; img sin alt=$noalt; schema=${types}${types2:-ninguno}"

  docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -q \
    -v url="$url" -v http="$code" -v puntaje="$puntaje" \
    -v hallazgos="$hallazgos" -v resumen="$resumen" <<'SQL' >/dev/null
INSERT INTO auditoria_sitio (prospecto_id, url, http_estado, puntaje, hallazgos, resumen)
VALUES (
  -- Se engancha al prospecto por el dominio, no por la URL completa: en la
  -- ficha está «orthovet.com» y aquí puede venir con https, con www o con
  -- una ruta. Si no calza con ninguno, la auditoría se guarda igual — un
  -- sitio auditado antes de existir el prospecto es el caso normal.
  (SELECT id FROM prospecto
    WHERE sitio IS NOT NULL
      AND regexp_replace(lower(:'url'),   '^https?://(www\.)?([^/]+).*$', '\2')
        = regexp_replace(lower(sitio), '^https?://(www\.)?([^/]+).*$', '\2')
    LIMIT 1),
  :'url', NULLIF(:'http','')::int, NULLIF(:'puntaje','')::int,
  :'hallazgos'::jsonb, :'resumen');
SQL
  echo "    → guardada en la base (puntaje $puntaje)"
done
