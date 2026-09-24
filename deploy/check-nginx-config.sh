#!/bin/sh
# Validates the production nginx configuration without a server, a domain or a
# real certificate: renders the template exactly as the nginx image's entrypoint
# does, points it at a throwaway self-signed certificate, and runs `nginx -t`.
#
# The development stack exercises the shared location rules on every CI run,
# but production is a different top-level file, a template and a TLS server
# block. A syntax error in any of those would otherwise first surface on the
# instance, as a container that restarts forever.
#
# Run from the repository root:
#   sh deploy/check-nginx-config.sh
# CONTAINER_ENGINE=podman selects podman; docker is the default.
set -eu

ENGINE="${CONTAINER_ENGINE:-docker}"
HOST="check.invalid"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/live/$HOST"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$HOST" \
    -keyout "$WORK/live/$HOST/privkey.pem" \
    -out "$WORK/live/$HOST/fullchain.pem" 2>/dev/null
chmod 644 "$WORK/live/$HOST/privkey.pem"

# The same mounts and the same envsubst filter as docker-compose.prod.yml. The
# replica names resolve to loopback because `nginx -t` resolves upstream hosts
# and there are no replicas here to resolve to.
"$ENGINE" run --rm \
    --add-host microservice-1:127.0.0.1 \
    --add-host microservice-2:127.0.0.1 \
    -e APP_HOSTNAME="$HOST" \
    -e NGINX_ENVSUBST_FILTER=APP_HOSTNAME \
    -v "$PWD/deploy/nginx.prod.conf:/etc/nginx/nginx.conf:ro" \
    -v "$PWD/deploy/templates:/etc/nginx/templates:ro" \
    -v "$PWD/nginx/api_locations.conf:/etc/nginx/api_locations.conf:ro" \
    -v "$PWD/nginx/api_http.conf:/etc/nginx/api_http.conf:ro" \
    -v "$WORK:/etc/letsencrypt:ro" \
    nginx:alpine \
    /docker-entrypoint.sh nginx -t
