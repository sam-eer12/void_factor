#!/usr/bin/env sh
# First-run TLS setup. Run once, from this directory, after APP_HOSTNAME resolves
# to this machine and ports 80/443 are actually reachable (see README.md — on OCI
# that means the VCN security list *and* the instance's own iptables).
#
# Solves the ordering problem: nginx will not start without a certificate, and
# certbot cannot obtain one without nginx serving the challenge. So a throwaway
# self-signed pair goes in first purely to let nginx boot, and is replaced by the
# real certificate a few seconds later.
#
# Safe to re-run: an existing Let's Encrypt certificate is left alone.
set -eu

COMPOSE="${COMPOSE:-docker-compose}"
FILE="docker-compose.prod.yml"

: "${APP_HOSTNAME:?set APP_HOSTNAME, e.g. export APP_HOSTNAME=1-2-3-4.sslip.io}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL for expiry notices}"

# --staging until you have seen it work: Let's Encrypt allows only 5 failed
# attempts per hostname per hour, and a typo burns them fast.
STAGING_FLAG=""
[ "${STAGING:-0}" = "1" ] && STAGING_FLAG="--staging"

live="/etc/letsencrypt/live/$APP_HOSTNAME"

echo "==> Seeding a temporary self-signed certificate so nginx can start"
$COMPOSE -f "$FILE" run --rm --entrypoint sh certbot -c "
  set -e
  if [ -f '$live/fullchain.pem' ]; then
    echo 'existing certificate found, leaving it alone'
    exit 0
  fi
  mkdir -p '$live'
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout '$live/privkey.pem' -out '$live/fullchain.pem' \
    -subj '/CN=$APP_HOSTNAME'
"

echo "==> Starting the stack"
$COMPOSE -f "$FILE" up -d

echo "==> Waiting for nginx to answer the challenge path"
i=0
until curl -fsS "http://$APP_HOSTNAME/.well-known/acme-challenge/ping" >/dev/null 2>&1 \
   || [ "$i" -ge 30 ]; do
  # A 404 from nginx is success here — it means nginx is up and routing. Only a
  # connection failure keeps us waiting.
  curl -sS -o /dev/null "http://$APP_HOSTNAME/" 2>/dev/null && break
  i=$((i + 1))
  sleep 2
done

echo "==> Requesting the real certificate"
# Deletes the self-signed placeholder first; certbot would otherwise treat it as
# an existing certificate and offer to renew rather than issue.
$COMPOSE -f "$FILE" run --rm --entrypoint sh certbot -c "
  set -e
  if openssl x509 -in '$live/fullchain.pem' -noout -issuer | grep -q 'CN=$APP_HOSTNAME'; then
    rm -rf '/etc/letsencrypt/live/$APP_HOSTNAME' \
           '/etc/letsencrypt/archive/$APP_HOSTNAME' \
           '/etc/letsencrypt/renewal/$APP_HOSTNAME.conf'
  fi
  certbot certonly --webroot -w /var/www/certbot $STAGING_FLAG \
    --email '$LETSENCRYPT_EMAIL' --agree-tos --no-eff-email \
    -d '$APP_HOSTNAME'
"

echo "==> Reloading nginx onto the real certificate"
$COMPOSE -f "$FILE" exec nginx nginx -s reload

echo
echo "Done. Verify with:  curl -sS https://$APP_HOSTNAME/health"
