#!/usr/bin/env bash
# Runs on the VM as root, called by cloud-init after this repository has been
# cloned. Everything it needs is in the repo, so a rebuilt VM is always this
# file's current state -- nothing is uploaded from a workstation.
set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCROOT=/var/www/novatrix

install -d -m 0755 "$DOCROOT"
install -m 0644 "$SITE_DIR/index.html" "$DOCROOT/index.html"

cat > /etc/nginx/sites-available/novatrix <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/novatrix;
    index index.html;

    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/novatrix /etc/nginx/sites-enabled/novatrix
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "novatrix site deployed from ${SITE_DIR}"
