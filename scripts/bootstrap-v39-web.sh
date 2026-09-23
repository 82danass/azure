#!/usr/bin/env bash
# v39, web: nginx serves the form, and the POST behind it goes to a small
# Python service that writes the errand as a row in the ticket registry on the
# ops machine. Runs as root from cloud-init, from the repository root.
#
# The service needs the registry's admin password, which mov delivers to
# /etc/mov/secrets.env after boot, never through cloud-init. So the service is
# installed here and started by mov-secrets.service the moment the file lands.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly DOCROOT=/var/www/mov
readonly APPROOT=/opt/novatrix-form
readonly SITE=mov
readonly SERVICE=novatrix-form

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] error: %s\n' "$*" >&2; exit 1; }

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing. cloud-init writes it; this script cannot run standalone."
source "$ENV_FILE"
for var in MOV_ENV MOV_REPO MOV_REF MOV_PATH MOV_APP_DIR NOVATRIX_TICKETS_URL NC_ADMIN_EMAIL; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done

readonly SOURCE_DIR="${MOV_APP_DIR%/}/${MOV_PATH#/}"
[[ -f $SOURCE_DIR/public/index.html ]] || fail "$SOURCE_DIR/public has no index.html. Check source.path in the profile."
[[ -f $SOURCE_DIR/app/form.py ]] || fail "$SOURCE_DIR/app has no form.py."
log "env=$MOV_ENV repo=$MOV_REPO ref=$MOV_REF serving=$SOURCE_DIR registry=$NOVATRIX_TICKETS_URL"

# --- packages: cloud-init installs these on first boot; this covers a re-run ---

export DEBIAN_FRONTEND=noninteractive
missing=()
for pkg in nginx python3-flask gunicorn; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    log "installing ${missing[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing[@]}"
fi

# --- content ------------------------------------------------------------------

install -d -m 0755 "$DOCROOT"
find "$DOCROOT" -mindepth 1 -delete
cp -a "$SOURCE_DIR/public/." "$DOCROOT/"
chown -R www-data:www-data "$DOCROOT"
find "$DOCROOT" -type d -exec chmod 0755 {} +
find "$DOCROOT" -type f -exec chmod 0644 {} +
log "deployed $(find "$DOCROOT" -type f | wc -l) file(s) to $DOCROOT"

# --- the service, installed now, started when the secrets land ------------------

install -d -m 0755 "$APPROOT" /opt/novatrix
install -m 0644 "$SOURCE_DIR/app/form.py" "$APPROOT/form.py"
install -m 0644 "$SOURCE_DIR/app/$SERVICE.service" "/etc/systemd/system/$SERVICE.service"
install -m 0644 "$SOURCE_DIR/app/mov-secrets.path" /etc/systemd/system/mov-secrets.path
install -m 0644 "$SOURCE_DIR/app/mov-secrets.service" /etc/systemd/system/mov-secrets.service
cat > /opt/novatrix/on-secrets.sh <<'ON'
#!/usr/bin/env bash
set -euo pipefail
systemctl enable --now novatrix-form
systemctl restart novatrix-form
ON
chmod 0755 /opt/novatrix/on-secrets.sh
chmod 0644 "$ENV_FILE"
systemctl daemon-reload
systemctl enable --now mov-secrets.path
# If the secrets are already there (a re-run), start straight away.
[[ -f /etc/mov/secrets.env ]] && systemctl start mov-secrets.service || true

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

    # The form posts here; the service behind it writes to the ticket registry.
    location = /arenden {
        client_max_body_size 1m;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    location = /health {
        proxy_pass http://127.0.0.1:8080;
    }
}
NGINX
ln -sf "/etc/nginx/sites-available/$SITE" "/etc/nginx/sites-enabled/$SITE"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx
log "nginx serves $DOCROOT and proxies /arenden to the form service"
