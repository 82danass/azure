#!/usr/bin/env bash
# ops, v39: körs av mov-secrets.service i samma sekund som mov levererat
# /etc/mov/secrets.env. Startar ärenderegistret, ser till att bas, tabell och
# webhook finns, skriver inloggningsproxyns konfiguration och startar
# notifieringen. Idempotent: körs igen utan att göra om något som finns.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly SECRETS_FILE=/etc/mov/secrets.env
readonly NOCO_DATA=/srv/nocodb
readonly NOCO=http://127.0.0.1:8080
readonly PROXY_CFG=/etc/oauth2-proxy/oauth2-proxy.cfg

log() { printf '[on-secrets] %s\n' "$*"; }
fail() { printf '[on-secrets] error: %s\n' "$*" >&2; exit 1; }

[[ -r $ENV_FILE && -r $SECRETS_FILE ]] || fail "$ENV_FILE or $SECRETS_FILE is missing"
set -a; source "$ENV_FILE"; source "$SECRETS_FILE"; set +a
for var in NOVATRIX_TICKET_HOST OAUTH_CLIENT_ID OAUTH_TENANT_ID NC_ADMIN_EMAIL \
           OAUTH_CLIENT_SECRET NC_AUTH_JWT_SECRET NC_ADMIN_PASSWORD OAUTH2_PROXY_COOKIE_SECRET; do
    [[ -n ${!var:-} ]] || fail "$var is not set"
done

# --- the ticket registry ------------------------------------------------------

install -d -m 0750 "$NOCO_DATA"
if ! docker inspect noco >/dev/null 2>&1; then
    log "starting NocoDB"
    docker run -d --name noco --restart unless-stopped -p 8080:8080 \
        -v "$NOCO_DATA":/usr/app/data/ \
        -e NC_AUTH_JWT_SECRET="$NC_AUTH_JWT_SECRET" \
        -e NC_ADMIN_EMAIL="$NC_ADMIN_EMAIL" -e NC_ADMIN_PASSWORD="$NC_ADMIN_PASSWORD" \
        -e NC_SITE_URL="https://$NOVATRIX_TICKET_HOST" -e NC_INVITE_ONLY_SIGNUP=true -e NC_DISABLE_TELE=true \
        -e NC_WEBHOOK_ALLOW_PRIVATE_NETWORK=true \
        nocodb/nocodb:latest >/dev/null
else
    docker start noco >/dev/null 2>&1 || true
fi
for _ in $(seq 1 60); do
    curl -sf "$NOCO/api/v1/health" >/dev/null 2>&1 && break
    sleep 3
done
curl -sf "$NOCO/api/v1/health" >/dev/null || fail "NocoDB did not answer on $NOCO"

api() {  # api METHOD PATH [JSON]
    local method=$1 path=$2 body=${3:-}
    if [[ -n $body ]]; then
        curl -sf -X "$method" "$NOCO$path" -H "xc-auth: $JWT" -H 'Content-Type: application/json' -d "$body"
    else
        curl -sf -X "$method" "$NOCO$path" -H "xc-auth: $JWT"
    fi
}

JWT=$(curl -sf -X POST "$NOCO/api/v2/auth/user/signin" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg e "$NC_ADMIN_EMAIL" --arg p "$NC_ADMIN_PASSWORD" '{email:$e,password:$p}')" | jq -r .token)
[[ -n $JWT && $JWT != null ]] || fail "could not sign in to NocoDB as $NC_ADMIN_EMAIL"

BASE_ID=$(api GET /api/v1/db/meta/projects/ | jq -r '.list[] | select(.title=="Novatrix") | .id' | head -1)
if [[ -z $BASE_ID ]]; then
    BASE_ID=$(api POST /api/v1/db/meta/projects/ '{"title":"Novatrix"}' | jq -r .id)
    log "created base Novatrix ($BASE_ID)"
fi
TABLE_ID=$(api GET "/api/v2/meta/bases/$BASE_ID/tables" | jq -r '.list[] | select(.title=="Arenden") | .id' | head -1)
if [[ -z $TABLE_ID ]]; then
    TABLE_ID=$(api POST "/api/v2/meta/bases/$BASE_ID/tables" '{
      "title":"Arenden","table_name":"arenden","columns":[
        {"column_name":"id","title":"Id","uidt":"ID","pk":true,"ai":true,"rqd":true},
        {"column_name":"name","title":"Name","uidt":"SingleLineText"},
        {"column_name":"email","title":"Email","uidt":"Email"},
        {"column_name":"message","title":"Message","uidt":"LongText"},
        {"column_name":"status","title":"Status","uidt":"SingleSelect","dtxp":"'"'"'ny'"'"','"'"'pagaende'"'"','"'"'klar'"'"'"},
        {"column_name":"received","title":"Received","uidt":"SingleLineText"},
        {"column_name":"handled_by","title":"HandledBy","uidt":"SingleLineText"}]}' | jq -r .id)
    log "created table Arenden ($TABLE_ID)"
fi
if ! api GET "/api/v2/meta/tables/$TABLE_ID/hooks" | jq -e '.list[] | select(.title=="notify")' >/dev/null; then
    api POST "/api/v2/meta/tables/$TABLE_ID/hooks" '{
      "title":"notify","event":"after","operation":"insert","type":"url","active":1,
      "notification":{"type":"URL","payload":{"method":"POST","path":"http://127.0.0.1:9000/ticket","body":"{{ json data }}","headers":[{}],"parameters":[{}],"auth":""}}}' >/dev/null
    log "created webhook notify -> 127.0.0.1:9000/ticket"
fi

# --- the sign-in door -----------------------------------------------------------

install -d -m 0750 "$(dirname "$PROXY_CFG")"
cat > "$PROXY_CFG" <<CFG
provider = "entra-id"
oidc_issuer_url = "https://login.microsoftonline.com/$OAUTH_TENANT_ID/v2.0"
client_id = "$OAUTH_CLIENT_ID"
client_secret = "$OAUTH_CLIENT_SECRET"
scope = "openid"
redirect_url = "https://$NOVATRIX_TICKET_HOST/oauth2/callback"
cookie_secret = "$OAUTH2_PROXY_COOKIE_SECRET"
email_domains = ["*"]
http_address = "0.0.0.0:4180"
upstream = "static://202"
reverse_proxy = true
set_xauthrequest = true
skip_provider_button = true
cookie_secure = true
CFG
chmod 0600 "$PROXY_CFG"
if docker inspect oauth2-proxy >/dev/null 2>&1; then
    docker rm -f oauth2-proxy >/dev/null
fi
docker run -d --name oauth2-proxy --restart unless-stopped -p 127.0.0.1:4180:4180 \
    -v "$PROXY_CFG":/etc/oauth2-proxy.cfg:ro \
    quay.io/oauth2-proxy/oauth2-proxy:v7.15.4 --config=/etc/oauth2-proxy.cfg >/dev/null
log "sign-in proxy up for https://$NOVATRIX_TICKET_HOST"

# --- notifications ----------------------------------------------------------------

systemctl restart novatrix-notify
systemctl reload nginx || systemctl restart nginx
log "done: registry, door and notifier are up"
