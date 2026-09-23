#!/usr/bin/env bash
# v39, ops: the ticket registry (NocoDB), the sign-in door in front of it
# (oauth2-proxy against Entra ID, nginx with TLS), and the notifier that turns
# a new ticket into a mail and a Teams notice. Runs as root from cloud-init.
#
# Everything is installed and pulled here. Nothing that needs a secret is
# started here: mov delivers /etc/mov/secrets.env after boot, and
# mov-secrets.service runs ops/on-secrets.sh the moment it lands.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly NOTIFY=/opt/novatrix-notify
readonly ACME=/var/www/acme
readonly IMDS_IP='http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text'

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] error: %s\n' "$*" >&2; exit 1; }

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing."
source "$ENV_FILE"
for var in MOV_ENV MOV_PATH MOV_APP_DIR OAUTH_CLIENT_ID OAUTH_TENANT_ID NOVATRIX_ACS_ID NOVATRIX_MAIL_DOMAIN_ID NOVATRIX_SUPPORT_EMAIL; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done
readonly SOURCE_DIR="${MOV_APP_DIR%/}/${MOV_PATH#/}"
[[ -f $SOURCE_DIR/ops/on-secrets.sh ]] || fail "$SOURCE_DIR/ops has no on-secrets.sh"

# --- the machine's own address becomes its hostname -------------------------------

PUBLIC_IP=$(curl -sf -H Metadata:true "$IMDS_IP" || true)
[[ -n $PUBLIC_IP ]] || fail "could not read the public address from the instance metadata"
readonly HOST="$PUBLIC_IP.sslip.io"
grep -q '^NOVATRIX_TICKET_HOST=' "$ENV_FILE" || printf 'NOVATRIX_TICKET_HOST=%s\n' "$HOST" >> "$ENV_FILE"
log "env=$MOV_ENV host=$HOST"

# --- packages and images ---------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
missing=()
for pkg in docker.io nginx certbot python3-venv jq curl openssl; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    log "installing ${missing[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing[@]}"
fi
systemctl enable --now docker
docker pull -q nocodb/nocodb:latest
docker pull -q quay.io/oauth2-proxy/oauth2-proxy:v7.15.4
log "images pulled"

# --- the notifier: a venv with the ACS SDK, started when the secrets land ------------

install -d -m 0755 "$NOTIFY" /opt/novatrix
if [[ ! -x $NOTIFY/venv/bin/gunicorn ]]; then
    python3 -m venv "$NOTIFY/venv"
    "$NOTIFY/venv/bin/pip" install -q --upgrade pip
    "$NOTIFY/venv/bin/pip" install -q flask gunicorn azure-communication-email azure-identity
    log "notifier venv built"
fi
install -m 0644 "$SOURCE_DIR/ops/notify.py" "$NOTIFY/notify.py"
install -m 0644 "$SOURCE_DIR/ops/novatrix-notify.service" /etc/systemd/system/novatrix-notify.service
install -m 0644 "$SOURCE_DIR/app/mov-secrets.path" /etc/systemd/system/mov-secrets.path
install -m 0644 "$SOURCE_DIR/app/mov-secrets.service" /etc/systemd/system/mov-secrets.service
install -m 0755 "$SOURCE_DIR/ops/on-secrets.sh" /opt/novatrix/on-secrets.sh
chmod 0644 "$ENV_FILE"
systemctl daemon-reload
systemctl enable novatrix-notify >/dev/null
systemctl enable --now mov-secrets.path

# --- TLS: Let's Encrypt for the address's hostname, self-signed if it refuses -------

install -d -m 0755 "$ACME/.well-known/acme-challenge"
CERT=/etc/ssl/tickets.crt
KEY=/etc/ssl/tickets.key
render_site() {  # render_site CERT KEY
    sed -e "s|__HOST__|$HOST|g" -e "s|__CERT__|$1|g" -e "s|__KEY__|$2|g" \
        "$SOURCE_DIR/ops/tickets.nginx" > /etc/nginx/sites-available/tickets
    ln -sf /etc/nginx/sites-available/tickets /etc/nginx/sites-enabled/tickets
    rm -f /etc/nginx/sites-enabled/default
}
if [[ ! -s $CERT ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 90 -subj "/CN=$HOST" -keyout "$KEY" -out "$CERT" 2>/dev/null
    log "self-signed certificate for $HOST, until Let's Encrypt answers"
fi
render_site "$CERT" "$KEY"
nginx -t && systemctl enable --now nginx && systemctl reload nginx

LE_DIR=/etc/letsencrypt/live/$HOST
if [[ ! -s $LE_DIR/fullchain.pem ]]; then
    if timeout 120 certbot certonly --webroot -w "$ACME" -d "$HOST" --non-interactive --agree-tos \
            --register-unsafely-without-email --quiet; then
        log "Let's Encrypt issued a certificate for $HOST"
    else
        log "Let's Encrypt did not issue for $HOST (rate limit on sslip.io is shared); staying self-signed"
    fi
fi
if [[ -s $LE_DIR/fullchain.pem ]]; then
    render_site "$LE_DIR/fullchain.pem" "$LE_DIR/privkey.pem"
    nginx -t && systemctl reload nginx
fi

# If the secrets are already there (a re-run), start straight away.
[[ -f /etc/mov/secrets.env ]] && systemctl start mov-secrets.service || true
log "ready for the secrets: https://$HOST"
