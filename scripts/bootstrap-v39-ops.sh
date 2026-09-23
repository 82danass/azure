#!/usr/bin/env bash
# v39, ops: the ticket registry (NocoDB), the tunnel that gives it a hostname
# without opening a port, and the notifier that turns a new ticket into a mail
# and a Teams notice. Runs as root from cloud-init, from the repository root.
#
# Everything is installed and pulled here. Nothing that needs a secret is
# started here: mov delivers /etc/mov/secrets.env after boot, and
# mov-secrets.service runs ops/on-secrets.sh the moment it lands. The sign-in
# in front of the registry is Cloudflare Access, made by mov's cloudflare stage;
# nothing on this machine handles it.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly NOTIFY=/opt/novatrix-notify
readonly KEYRING=/usr/share/keyrings/cloudflare-main.gpg

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] error: %s\n' "$*" >&2; exit 1; }

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing."
source "$ENV_FILE"
for var in MOV_ENV MOV_PATH MOV_APP_DIR NOVATRIX_TICKET_HOST NOVATRIX_ACS_ID NOVATRIX_MAIL_DOMAIN_ID NOVATRIX_SUPPORT_EMAIL NC_ADMIN_EMAIL; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done
readonly SOURCE_DIR="${MOV_APP_DIR%/}/${MOV_PATH#/}"
[[ -f $SOURCE_DIR/ops/on-secrets.sh ]] || fail "$SOURCE_DIR/ops has no on-secrets.sh"
log "env=$MOV_ENV host=$NOVATRIX_TICKET_HOST"

# --- packages, the tunnel connector, the images ---------------------------------------

export DEBIAN_FRONTEND=noninteractive
missing=()
for pkg in docker.io python3-venv jq curl; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    log "installing ${missing[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing[@]}"
fi
if ! command -v cloudflared >/dev/null 2>&1; then
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o "$KEYRING"
    echo "deb [signed-by=$KEYRING] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq && apt-get install -y -qq cloudflared
    log "cloudflared installed"
fi
systemctl enable --now docker
docker pull -q nocodb/nocodb:latest
log "image pulled"

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

# If the secrets are already there (a re-run), start straight away.
[[ -f /etc/mov/secrets.env ]] && systemctl start mov-secrets.service || true
log "ready for the secrets: https://$NOVATRIX_TICKET_HOST through the tunnel"
