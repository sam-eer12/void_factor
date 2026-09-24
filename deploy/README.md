# Deploying to OCI

The stack is nginx (TLS + per-user rate limiting) in front of the FastAPI
analysis service. It fits inside OCI's Always Free tier: one Ampere A1 VM is
enough, and the images are multi-arch so ARM needs no special build.

## 1. The instance

Create an **Ampere A1 (aarch64)** VM — Ubuntu 22.04 or Oracle Linux 9 — with a
public IP. Install a container engine and the compose binary.

Then open the ports. **This is two steps, and skipping the second is the single
most common way this deploy fails:**

1. **VCN security list** — add ingress rules for TCP 80 and 443 from `0.0.0.0/0`.
2. **The instance's own firewall** — Oracle's images ship restrictive local
   rules that drop 80/443 even after the security list allows them:

   ```sh
   # Ubuntu images (iptables)
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
   sudo netfilter-persistent save

   # Oracle Linux images (firewalld)
   sudo firewall-cmd --permanent --add-service=http --add-service=https
   sudo firewall-cmd --reload
   ```

A deploy that fails only here looks exactly like a DNS problem: the name
resolves, the connection just hangs.

## 2. A hostname

TLS needs a name, not an IP. You do not need to buy one to start:
`<ip-with-dashes>.sslip.io` resolves to that IP and Let's Encrypt issues for it,
free. `203.0.113.7` becomes `203-0-113-7.sslip.io`.

Buying a domain later is a one-line change to `APP_HOSTNAME` plus a re-run of
`bootstrap-tls.sh`. Nothing else in the config names a host.

## 3. Configuration

```sh
git clone <repo> /opt/void_factor
cd /opt/void_factor/deploy
cp .env.example .env          # set APP_HOSTNAME, LETSENCRYPT_EMAIL
cp ../microservice/.env.example ../microservice/.env
```

`FIREBASE_PROJECT_ID` must match the app's Firebase project. If it is unset the
service returns **503 on every `/api/` route** rather than accepting unverified
callers — a misconfigured deploy reports itself instead of quietly running open.

Leave the provider keys in `microservice/.env` **blank in production**. They are
a local-testing convenience; users supply their own key per request, and a
populated fallback would spend your quota on anyone who omits one.

## 4. First run

```sh
export $(grep -v '^#' .env | xargs)
STAGING=1 ./bootstrap-tls.sh     # dry run against Let's Encrypt staging
./bootstrap-tls.sh               # the real certificate
```

Run it with `STAGING=1` first. Let's Encrypt allows five failed attempts per
hostname per hour, and a typo in `APP_HOSTNAME` burns them in under a minute.
Staging issues an untrusted certificate from an unlimited pool, which is exactly
what you want while confirming the plumbing.

Verify:

```sh
sh verify-live.sh "$APP_HOSTNAME"
```

It checks, from the outside and without credentials: `/health` over a trusted
certificate, HSTS, the HTTP→HTTPS redirect, an unauthenticated scan refused by
the edge with `auth:` JSON, a spoofed `X-Verified-Uid` buying nothing, and
`/internal/verify` not being reachable. Run it from your laptop too — a check
that only passes on the box itself has not tested the firewall.

A `503` with `auth:` means the verifier is not answering: usually an unset
`FIREBASE_PROJECT_ID`.

**Check that nginx sees real client addresses.** The per-address limit keys on
them, and some container engines' port forwarding replaces every client with
the bridge gateway. That is safe by construction — private addresses are exempt,
so it degrades to no per-address limit rather than one shared limit for everyone
— but it is a limit you then do not have. After a request from your laptop:

```sh
docker-compose -f docker-compose.prod.yml logs nginx | tail -3
```

The client address on the request line should be your public IP, not a
`10.x`/`172.x` one. Rootful Docker and rootful Podman preserve it; rootless
engines often do not.

## 5. Boot persistence

```sh
sudo cp voidfactor.service /etc/systemd/system/
sudo systemctl enable --now voidfactor
```

## 6. Point the app at it

The Flutter client defaults to localhost, so a release build must be told:

```sh
flutter build apk --release \
  --dart-define=FOOD_API_BASE_URL=https://$APP_HOSTNAME
```

Without the flag the app builds fine and every scan fails with
"CAN'T REACH ANALYSIS SERVICE".

## Updating

```sh
cd /opt/void_factor && git pull
sudo systemctl reload voidfactor     # up -d --build
```

## Renewal

The certbot sidecar checks twice a day and renews inside 30 days of expiry;
nginx reloads every 6 hours to pick up a new certificate. Neither needs
attention. To confirm renewal works before it matters:

```sh
docker-compose -f docker-compose.prod.yml run --rm certbot renew --dry-run
```

## What this deployment does not do

- **No per-day quota.** nginx limits per minute only. A hard daily cap needs
  Redis or Lua.
- **No horizontal scaling.** One box, one nginx, in-memory rate-limit state.
