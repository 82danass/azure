#!/usr/bin/env bash
# web, v39: the certificate for the form's hostname, from Let's Encrypt, and
# a 443 server block once it exists. The proof is HTTP-01 through Cloudflare's
# edge: Let's Encrypt fetches a file under /.well-known on the hostname, the
# edge forwards it to port 80 here. Run by novatrix-cert.service, which
# retries every half minute until it succeeds: the record is made after this
# machine is, so the first attempts find no name yet. That is expected.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly DOCROOT=/var/www/mov
readonly SITE=/etc/nginx/sites-available/mov-tls
readonly LOG=/run/novatrix-cert.log

log() { printf '[get-cert] %s\n' "$*"; }

[[ -r $ENV_FILE ]] || { log "$ENV_FILE is missing"; exit 1; }
source "$ENV_FILE"
: "${NOVATRIX_FORM_HOST:?NOVATRIX_FORM_HOST is not set in $ENV_FILE}"
readonly HOST=$NOVATRIX_FORM_HOST
readonly LIVE=/etc/letsencrypt/live/$HOST

serve_tls() {
    cat > "$SITE" <<NGINX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $HOST;

    ssl_certificate $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $DOCROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

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
    ln -sf "$SITE" /etc/nginx/sites-enabled/mov-tls
    nginx -t && systemctl reload nginx
    log "https://$HOST is served from this machine"
}

if [[ -s $LIVE/fullchain.pem ]]; then
    log "certificate for $HOST present"
    serve_tls
    exit 0
fi

# The name must exist and must reach this machine through the edge before
# Let's Encrypt is asked; asking earlier only spends the failed-validation
# allowance.
install -d -m 0755 "$DOCROOT/.well-known"
echo "$(hostname)" > "$DOCROOT/.well-known/novatrix-probe"
if ! getent hosts "$HOST" >/dev/null 2>&1; then
    log "$HOST has no address yet"
    exit 1
fi
seen=$(curl -s --max-time 15 "http://$HOST/.well-known/novatrix-probe" || true)
if [[ $seen != "$(hostname)" ]]; then
    log "$HOST does not reach this machine yet (got '${seen:0:40}')"
    exit 1
fi

if ! certbot certonly --webroot -w "$DOCROOT" -d "$HOST" --non-interactive --agree-tos \
        --register-unsafely-without-email --deploy-hook "systemctl reload nginx" >"$LOG" 2>&1; then
    if grep -qi "too many certificates" "$LOG"; then
        # Five certificates a week for one exact name is Let's Encrypt's rule.
        # Retrying walks into the same wall; the reason is left where the
        # verify check and journalctl find it, and the service stops.
        log "Let's Encrypt has issued five certificates for $HOST this week; the next is possible when the oldest is a week old"
        exit 0
    fi
    log "certbot failed: $(tail -n 3 "$LOG" | tr '\n' ' ')"
    exit 1
fi
log "certificate issued for $HOST"
serve_tls
