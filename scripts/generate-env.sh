#!/usr/bin/env bash
# Génère un .env complet pour la stack AppFlowy, avec des secrets aléatoires.
# Toutes les valeurs sont écrites "à plat" (sans ${VAR} imbriquées) pour que le
# fichier fonctionne aussi bien avec `docker compose` qu'avec l'import .env de Portainer.
#
# Usage : scripts/generate-env.sh <fqdn> <email_admin> [fichier_sortie]
#   ex.  : scripts/generate-env.sh appflowy.jo.priv admin@jo.priv /volume2/docker/appflowy/.env
set -euo pipefail

FQDN="${1:?usage: $0 <fqdn> <email_admin> [fichier_sortie]}"
ADMIN_EMAIL="${2:?usage: $0 <fqdn> <email_admin> [fichier_sortie]}"
OUT="${3:-.env}"
DATA_DIR="${APPFLOWY_DATA_DIR:-/volume2/docker/appflowy}"

if [ -e "$OUT" ]; then
  echo "Refus : $OUT existe déjà (les secrets seraient perdus). Supprime-le ou choisis un autre chemin." >&2
  exit 1
fi

# Uniquement alphanumérique : utilisable tel quel dans les URL postgres:// sans échappement.
rand() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

BASE_URL="https://${FQDN}"
PG_USER=postgres
PG_DB=postgres
PG_PASS="$(rand 32)"
S3_KEY="$(rand 20)"
S3_SECRET="$(rand 40)"
JWT_SECRET="$(rand 64)"
ADMIN_PASS="$(rand 24)"
PG_URL="postgres://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}"

umask 077
cat > "$OUT" <<ENV
# Généré le $(date -Iseconds) par scripts/generate-env.sh — NE PAS COMMITER
APPFLOWY_DATA_DIR=${DATA_DIR}

FQDN=${FQDN}
APPFLOWY_BASE_URL=${BASE_URL}
APPFLOWY_WEB_URL=${BASE_URL}
APPFLOWY_WEBSOCKET_BASE_URL=wss://${FQDN}/ws/v2
API_EXTERNAL_URL=${BASE_URL}/gotrue

POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${PG_DB}
APPFLOWY_DATABASE_URL=${PG_URL}
GOTRUE_DATABASE_URL=${PG_URL}?search_path=auth
APPFLOWY_REDIS_URI=redis://redis:6379

GOTRUE_ADMIN_EMAIL=${ADMIN_EMAIL}
GOTRUE_ADMIN_PASSWORD=${ADMIN_PASS}
GOTRUE_JWT_SECRET=${JWT_SECRET}
GOTRUE_JWT_EXP=604800
GOTRUE_MAILER_AUTOCONFIRM=true
GOTRUE_DISABLE_SIGNUP=false

APPFLOWY_S3_ACCESS_KEY=${S3_KEY}
APPFLOWY_S3_SECRET_KEY=${S3_SECRET}
APPFLOWY_S3_BUCKET=appflowy
APPFLOWY_S3_CREATE_BUCKET=true
APPFLOWY_S3_PRESIGNED_URL_ENDPOINT=${BASE_URL}/minio-api

# SMTP (optionnel — vide = pas d'e-mails, d'où GOTRUE_MAILER_AUTOCONFIRM=true)
GOTRUE_SMTP_HOST=
GOTRUE_SMTP_PORT=465
GOTRUE_SMTP_USER=
GOTRUE_SMTP_PASS=
GOTRUE_SMTP_ADMIN_EMAIL=
APPFLOWY_MAILER_SMTP_HOST=
APPFLOWY_MAILER_SMTP_PORT=465
APPFLOWY_MAILER_SMTP_USERNAME=
APPFLOWY_MAILER_SMTP_EMAIL=
APPFLOWY_MAILER_SMTP_PASSWORD=
APPFLOWY_MAILER_SMTP_TLS_KIND=wrapper

# IA (optionnel — sans clé, les fonctions IA sont simplement indisponibles)
AI_OPENAI_API_KEY=
AZURE_OPENAI_API_KEY=
AZURE_OPENAI_ENDPOINT=
AZURE_OPENAI_API_VERSION=
ASSEMBLYAI_API_KEY=

RUST_LOG=info
ENV

echo "Écrit : $OUT (droits 600)"
echo "Compte admin GoTrue : ${ADMIN_EMAIL} / ${ADMIN_PASS}"
echo "Note ce mot de passe dans ton gestionnaire de mots de passe."
