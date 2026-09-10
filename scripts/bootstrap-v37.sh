#!/usr/bin/env bash
# v37: the static form is served by nginx, and the POST behind it goes to a
# small Python service that writes each errand to Blob with the machine's
# managed identity. Runs as root from cloud-init, from the repository root.
#
# Expects source.path to name the week's folder (v37), holding public/ and app/.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly DOCROOT=/var/www/mov
readonly APPROOT=/opt/novatrix-form
readonly SITE=mov
readonly SERVICE=novatrix-form
readonly STAMP=/etc/mov/deployed.json

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] error: %s\n' "$*" >&2; exit 1; }

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing. cloud-init writes it; this script cannot run standalone."
source "$ENV_FILE"
for var in MOV_ENV MOV_REPO MOV_REF MOV_PATH MOV_APP_DIR NOVATRIX_STORAGE_ACCOUNT; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done

readonly SOURCE_DIR="${MOV_APP_DIR%/}/${MOV_PATH#/}"
[[ -f $SOURCE_DIR/public/index.html ]] || fail "$SOURCE_DIR/public has no index.html. Check source.path in the profile."
[[ -f $SOURCE_DIR/app/form.py ]] || fail "$SOURCE_DIR/app has no form.py."

log "env=$MOV_ENV repo=$MOV_REPO ref=$MOV_REF serving=$SOURCE_DIR storage=$NOVATRIX_STORAGE_ACCOUNT"

# --- packages -----------------------------------------------------------------

# cloud-init installs these on first boot. This covers a manual re-run.
export DEBIAN_FRONTEND=noninteractive
missing=()
for pkg in nginx python3-flask gunicorn; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    log "installing ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
fi

# --- content ------------------------------------------------------------------

install -d -m 0755 "$DOCROOT"
find "$DOCROOT" -mindepth 1 -delete
cp -a "$SOURCE_DIR/public/." "$DOCROOT/"
chown -R www-data:www-data "$DOCROOT"
find "$DOCROOT" -type d -exec chmod 0755 {} +
find "$DOCROOT" -type f -exec chmod 0644 {} +
log "deployed $(find "$DOCROOT" -type f | wc -l) file(s) to $DOCROOT"

# --- the service --------------------------------------------------------------

install -d -m 0755 "$APPROOT"
install -m 0644 "$SOURCE_DIR/app/form.py" "$APPROOT/form.py"
install -m 0644 "$SOURCE_DIR/app/$SERVICE.service" "/etc/systemd/system/$SERVICE.service"
chmod 0644 "$ENV_FILE"
systemctl daemon-reload
systemctl enable --now "$SERVICE"
systemctl restart "$SERVICE"

# --- server block -------------------------------------------------------------

cat > "/etc/nginx/sites-available/$SITE" <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root $DOCROOT;
    index index.html;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # The form posts here; the service behind it writes to Blob.
    location = /arenden {
        client_max_body_size 12m;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    location = /health {
        proxy_pass http://127.0.0.1:8080;
    }

    # Dotfiles are not served.
    location ~ /\. {
        deny all;
    }
}
NGINX

ln -sfn "/etc/nginx/sites-available/$SITE" "/etc/nginx/sites-enabled/$SITE"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# --- record what is actually running ------------------------------------------

install -d -m 0755 "$(dirname "$STAMP")"
cat > "$STAMP" <<JSON
{
  "env": "$MOV_ENV",
  "repo": "$MOV_REPO",
  "ref": "$MOV_REF",
  "path": "$MOV_PATH",
  "storage": "$NOVATRIX_STORAGE_ACCOUNT",
  "commit": "$(git -C "$MOV_APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

log "done. $(tr -d '\n ' < "$STAMP")"
