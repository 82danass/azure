#!/usr/bin/env bash
# ops, v39: run by mov-secrets.service in the same second mov has delivered
# /etc/mov/secrets.env. Starts the ticket registry, makes sure base, table and
# webhook exist, connects the tunnel with its token, and starts the notifier.
# Idempotent: runs again without redoing what exists.
set -euo pipefail

readonly ENV_FILE=/etc/mov/deploy.env
readonly SECRETS_FILE=/etc/mov/secrets.env
readonly NOCO_DATA=/srv/nocodb
readonly NOCO=http://127.0.0.1:8080

log() { printf '[on-secrets] %s\n' "$*"; }
fail() { printf '[on-secrets] error: %s\n' "$*" >&2; exit 1; }

[[ -r $ENV_FILE && -r $SECRETS_FILE ]] || fail "$ENV_FILE or $SECRETS_FILE is missing"
set -a; source "$ENV_FILE"; source "$SECRETS_FILE"; set +a
# TUNNEL_TOKEN only in the profile with Cloudflare (v39-cf); without it the
# registry is reached on this machine's own address and no tunnel starts.
for var in NOVATRIX_TICKET_HOST NC_ADMIN_EMAIL NC_AUTH_JWT_SECRET NC_ADMIN_PASSWORD; do
    [[ -n ${!var:-} ]] || fail "$var is not set"
done

# --- the ticket registry ------------------------------------------------------

install -d -m 0750 "$NOCO_DATA"
# On the host's network: the webhook's 127.0.0.1:9000 then means this machine,
# where the notifier listens, and not the container's own loopback.
if ! docker inspect noco >/dev/null 2>&1; then
    log "starting NocoDB"
    docker run -d --name noco --restart unless-stopped --network host \
        -v "$NOCO_DATA":/usr/app/data/ \
        -e NC_AUTH_JWT_SECRET="$NC_AUTH_JWT_SECRET" \
        -e NC_ADMIN_EMAIL="$NC_ADMIN_EMAIL" -e NC_ADMIN_PASSWORD="$NC_ADMIN_PASSWORD" \
        -e NC_SITE_URL="${NOVATRIX_SITE_URL:-https://$NOVATRIX_TICKET_HOST}" -e NC_INVITE_ONLY_SIGNUP=true -e NC_DISABLE_TELE=true \
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

api() {  # api METHOD PATH [JSON]: the body on success; on anything else, what NocoDB said
    local method=$1 path=$2 body=${3:-} answer code
    if [[ -n $body ]]; then
        answer=$(curl -s -w '\n%{http_code}' -X "$method" "$NOCO$path" -H "xc-auth: $JWT" -H 'Content-Type: application/json' -d "$body")
    else
        answer=$(curl -s -w '\n%{http_code}' -X "$method" "$NOCO$path" -H "xc-auth: $JWT")
    fi
    code=${answer##*$'\n'}
    [[ $code == 2* ]] || fail "$method $path answered $code: ${answer%$'\n'*}"
    printf '%s' "${answer%$'\n'*}"
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
# A version-3 hook: the only kind this NocoDB takes. Without a body template
# it sends an empty request; {{ json event }} is the whole event,
# {"type":"records.after.insert","data":{"rows":[...]}}, which notify.py reads.
if ! api GET "/api/v2/meta/tables/$TABLE_ID/hooks" | jq -e '.list[] | select(.title=="notify")' >/dev/null; then
    api POST "/api/v2/meta/tables/$TABLE_ID/hooks" '{
      "title":"notify","version":"v3","event":"after","operation":["insert"],"active":true,
      "notification":{"type":"URL","payload":{"method":"POST","path":"http://127.0.0.1:9000/ticket","body":"{{ json event }}","headers":[],"parameters":[],"auth":""}}}' >/dev/null
    log "created webhook notify -> 127.0.0.1:9000/ticket"
fi

# --- the tunnel: the hostname without a port ------------------------------------

if [[ -n ${TUNNEL_TOKEN:-} ]]; then
    if systemctl list-unit-files cloudflared.service >/dev/null 2>&1 && systemctl is-enabled -q cloudflared 2>/dev/null; then
        cloudflared service uninstall >/dev/null 2>&1 || true
    fi
    cloudflared service install "$TUNNEL_TOKEN" >/dev/null
    systemctl restart cloudflared
    log "tunnel connected for https://$NOVATRIX_TICKET_HOST"
else
    log "no tunnel token delivered: the registry answers on this machine's address, port 8080"
fi

# --- notifications ----------------------------------------------------------------

systemctl restart novatrix-notify
log "done: registry, tunnel and notifier are up"
