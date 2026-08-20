#!/usr/bin/env bash
#
# Host provisioning. cloud-init clones this repository to $MOV_APP_DIR on first
# boot and then runs this script as root.
#
# No week, site or repository name is hardcoded. Configuration is read from
# /etc/mov/deploy.env, which cloud-init writes from the deployment profile:
#
#   MOV_WEEK      the profile that produced this host
#   MOV_REPO      owner/name of the repository that was cloned
#   MOV_REF       the branch or tag that was cloned
#   MOV_PATH      directory inside the repo to serve, relative to MOV_APP_DIR
#   MOV_APP_DIR   where the repository was cloned
#
# Safe to re-run: it redeploys from whatever is currently checked out.

set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly DOCROOT=/var/www/mov
readonly SITE=mov
readonly STAMP=/etc/mov/deployed.json

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] error: %s\n' "$*" >&2; exit 1; }

# --- configuration ----------------------------------------------------------

[[ -r $ENV_FILE ]] || fail "$ENV_FILE is missing. cloud-init writes it; this script cannot run standalone."
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in MOV_WEEK MOV_REPO MOV_REF MOV_PATH MOV_APP_DIR; do
    [[ -n ${!var:-} ]] || fail "$var is not set in $ENV_FILE"
done

readonly SOURCE_DIR="${MOV_APP_DIR%/}/${MOV_PATH#/}"
[[ -d $SOURCE_DIR ]] || fail "$SOURCE_DIR does not exist. Check source.path in the profile."
[[ -f $SOURCE_DIR/index.html ]] || fail "$SOURCE_DIR has no index.html."

log "week=$MOV_WEEK repo=$MOV_REPO ref=$MOV_REF serving=$SOURCE_DIR"

# --- nginx ------------------------------------------------------------------

# cloud-init installs nginx on first boot. This covers a manual re-run.
if ! command -v nginx >/dev/null 2>&1; then
    log "installing nginx"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nginx
fi

# --- content ----------------------------------------------------------------

# Replace rather than merge, so a file deleted in the repo also disappears here.
install -d -m 0755 "$DOCROOT"
find "$DOCROOT" -mindepth 1 -delete
cp -a "$SOURCE_DIR/." "$DOCROOT/"
chown -R www-data:www-data "$DOCROOT"
find "$DOCROOT" -type d -exec chmod 0755 {} +
find "$DOCROOT" -type f -exec chmod 0644 {} +

log "deployed $(find "$DOCROOT" -type f | wc -l) file(s) to $DOCROOT"

# --- server block -----------------------------------------------------------

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

# --- record what is actually running ----------------------------------------

install -d -m 0755 "$(dirname "$STAMP")"
cat > "$STAMP" <<JSON
{
  "week": "$MOV_WEEK",
  "repo": "$MOV_REPO",
  "ref": "$MOV_REF",
  "path": "$MOV_PATH",
  "commit": "$(git -C "$MOV_APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

log "done. $(cat "$STAMP" | tr -d '\n ')"
