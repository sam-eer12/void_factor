# Void Factor on an OCI Always Free instance

A setup guide for **one Ubuntu 24.04 ARM instance**, running the repository's
Nginx edge, two FastAPI containers, and Certbot. Gemma weights are served from
read-only VM storage. This is a guide; no OCI resources were provisioned as part
of writing it. Provider API keys stay blank on the server.

## 1. Choose the instance

Checked against Oracle's documentation on **30 September 2026**:

| Setting | Use |
| --- | --- |
| Region | Your tenancy's home region |
| Shape | `VM.Standard.A1.Flex` |
| CPU / RAM | **2 OCPUs / 12 GB**, within the current published A1 free allowance |
| Image | Canonical Ubuntu 24.04, ARM, Always Free eligible |
| Boot volume | 50 GB, default performance; account-wide boot + block storage within 200 GB |
| Network | Public subnet, internet gateway, route `0.0.0.0/0` to that gateway |
| Address | Public IPv4 address |
| SSH | Your public key; keep the private key on your laptop |

Oracle currently lists **1,500 OCPU-hours and 9,000 GB-hours/month** for A1;
older 4 OCPU / 24 GB instructions should not be used as your free-tier budget.
Check **Governance & Administration → Limits, Quotas and Usage** for your
actual tenancy before creating the VM. Capacity can be unavailable; retry in
another availability domain in the home region or later.
[Oracle Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

In **Compute → Instances → Create instance**, apply the settings above and
save the public IP. For the public subnet, add **stateful ingress** rules to its
security list or an attached network security group:

| Source | Protocol | Destination port | Purpose |
| --- | --- | --- | --- |
| Your laptop's public IP `/32` | TCP | 22 | SSH |
| `0.0.0.0/0` | TCP | 80 | TLS challenge + HTTP redirect |
| `0.0.0.0/0` | TCP | 443 | App API + model downloads |

Leave source ports unrestricted. Keep outbound DNS and HTTPS available for
provider calls, Google signing keys, image pulls, and certificate renewal.
The API containers' port 8000 and Nginx's loopback port 8081 are not public.
[Oracle's Ubuntu instance/network walkthrough](https://docs.oracle.com/en-us/iaas/Content/developer/wp-on-ubuntu/01-summary.htm).

## 2. Connect and copy this version of the project

**On your laptop**, substitute your real key path and public IP:

```sh
VF_OCI_IP=YOUR_PUBLIC_IP
VF_OCI_KEY=/path/to/your/oci-private-key
chmod 600 "$VF_OCI_KEY"
ssh -i "$VF_OCI_KEY" "ubuntu@$VF_OCI_IP"
```

In that **VM terminal**, install the transfer utility before copying files:

```sh
sudo apt-get update
sudo apt-get install -y rsync
```

To deploy the current working tree, including changes not yet committed, run
this **from the repository root on your laptop** in a second terminal:

```sh
rsync -av -e "ssh -i $VF_OCI_KEY" \
  --exclude='.env' --exclude='.venv' --exclude='__pycache__' \
  --exclude='.pytest_cache' --exclude='loadtest/results/' \
  deploy microservice nginx assets \
  "ubuntu@$VF_OCI_IP:/home/ubuntu/void_factor_upload/"
```

These four directories are sufficient for the server build. Alternatively,
clone the repository into `/opt/void_factor` after the intended changes are
committed, using your authorized repository access. Do not put access tokens
inside a Git URL.

**On the VM**, enter an administrator shell. All VM commands below run in this
shell unless labeled “laptop”:

```sh
sudo -i
install -d -m 0755 /opt/void_factor
cp -a /home/ubuntu/void_factor_upload/. /opt/void_factor/
apt-get update
apt-get install -y ca-certificates curl git python3 openssl dnsutils nano
uname -m
```

`uname -m` should report `aarch64`.

## 3. Install Docker and Compose

Use Docker's Ubuntu package repository. The ARM architecture is selected from
the machine automatically:

```sh
install -d -m 0755 /etc/apt/keyrings
VF_DOCKER_REPO=https://download.docker.com/linux/ubuntu
curl -fsSL "$VF_DOCKER_REPO/gpg" -o /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/docker.asc
. /etc/os-release
VF_OS_CODENAME=${UBUNTU_CODENAME:-$VERSION_CODENAME}
VF_OS_ARCH=$(dpkg --print-architecture)
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $VF_DOCKER_REPO
Suites: $VF_OS_CODENAME
Components: stable
Architectures: $VF_OS_ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker compose version
```

On a fresh Ubuntu image no conflicting Docker packages should be installed.
For an existing installation, follow Docker's package-conflict instructions
before replacing it. [Docker's Ubuntu installation guide](https://docs.docker.com/engine/install/ubuntu/).

The repository's bootstrap script and systemd unit call
`/usr/local/bin/docker-compose`. Give them a wrapper for the installed Compose
plugin; if that path already contains a working Compose binary, keep it:

```sh
if [ ! -e /usr/local/bin/docker-compose ]; then
  cat > /usr/local/bin/docker-compose <<'EOF'
#!/bin/sh
exec /usr/bin/docker compose "$@"
EOF
  chmod 0755 /usr/local/bin/docker-compose
fi
/usr/local/bin/docker-compose version
```

Set bounded logs **before** creating the app containers. This merges the
logging settings into any existing Docker configuration:

```sh
install -d /etc/docker
python3 - <<'PY'
import json
from pathlib import Path
path = Path('/etc/docker/daemon.json')
settings = json.loads(path.read_text()) if path.exists() else {}
settings['log-driver'] = 'local'
settings['log-opts'] = {'max-size': '20m', 'max-file': '5'}
path.write_text(json.dumps(settings, indent=2) + '\n')
PY
systemctl restart docker
```

These defaults apply to newly created containers. Retain separate usage records
if you need a whole month's bandwidth history; rotated logs are not a monthly
ledger. [Docker logging configuration](https://docs.docker.com/engine/logging/configure/).

## 4. Check the VM firewall

The OCI network rules and the VM firewall are separate. Inspect the existing
rules and allow HTTP/HTTPS ahead of a reject rule, preserving SSH:

```sh
iptables -L INPUT -n --line-numbers
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
```

If `netfilter-persistent` is available, save these rules with
`netfilter-persistent save`. Otherwise install `iptables-persistent` to persist
them. Do not flush the existing rules. Oracle documents the additional Ubuntu
firewall step in its [Ubuntu walkthrough](https://docs.oracle.com/en-us/iaas/Content/developer/wp-on-ubuntu/01-summary.htm).

Docker-published ports use forwarding rules and may bypass UFW's INPUT rules.
The OCI security rules still apply; only Nginx publishes host ports in this
Compose stack. If a connection still times out, inspect `iptables -S FORWARD`
and `iptables -S DOCKER-USER` as well.
[Docker firewall behavior](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations).

## 5. Choose the hostname

Point your domain's A record, for example `api.example.com`, to the VM's public
IPv4. Only publish an AAAA record if IPv6 is also routed and served correctly.

For an initial hostname without buying a domain, use your **actual public IP**
with dashes: `YOUR-IP-WITH-DASHES.sslip.io`. This DNS service resolves the
embedded address, and supports individually issued TLS certificates for public
hosts. [sslip.io documentation](https://sslip.io/).

The existing Nginx template expects a hostname certificate. Set:

```sh
VF_PUBLIC_IP=YOUR_PUBLIC_IP
VF_API_HOST=api.example.com
# Or: VF_API_HOST="$(printf '%s' "$VF_PUBLIC_IP" | tr . -).sslip.io"
dig +short A "$VF_API_HOST"
```

The DNS answer must include the VM's public IP before TLS bootstrap.

## 6. Set the two environment files

The deployment has **two different `.env` files**:

| File | What reads it | Contents |
| --- | --- | --- |
| `/opt/void_factor/deploy/.env` | Compose interpolation, bootstrap shell, systemd | Hostname, certificate email, Firebase project, model directory, stable project name |
| `/opt/void_factor/microservice/.env` | Both API containers via `env_file` | Model signing secret + public origin; provider defaults |

### Deployment environment

```sh
cd /opt/void_factor/deploy
cp .env.example .env
chmod 600 .env
nano .env
```

Replace the example hostname and email:

```dotenv
APP_HOSTNAME=api.example.com
LETSENCRYPT_EMAIL=YOUR_REAL_EMAIL
FIREBASE_PROJECT_ID=signinpractice-bfade
MODEL_DIRECTORY=/srv/void-factor/models
COMPOSE_PROJECT_NAME=voidfactor
```

`APP_HOSTNAME` is a bare hostname: no `https://`, path, or port. Keep
`COMPOSE_PROJECT_NAME` stable so updates use the same certificate volumes.
The example Firebase project is the one configured in this app; change it only
if you also use another Firebase project in the app.

### API environment

Create this once on the VM. The signing secret is generated directly into the
file, without printing it or placing it in shell history:

```sh
cd /opt/void_factor
umask 077
cp microservice/.env.example microservice/.env
python3 - <<'PY'
from pathlib import Path
import secrets
path = Path('microservice/.env')
text = path.read_text()
text = text.replace('MODEL_SIGNING_SECRET=\n',
                    'MODEL_SIGNING_SECRET=' + secrets.token_hex(32) + '\n')
path.write_text(text)
PY
chmod 600 microservice/.env
nano microservice/.env
```

The resulting file should have this shape; preserve the generated secret:

```dotenv
FIREBASE_PROJECT_ID=signinpractice-bfade
MODEL_SIGNING_SECRET=KEEP_THE_GENERATED_64_HEX_CHARACTERS
MODEL_PUBLIC_ORIGIN=https://api.example.com
MODEL_MANIFEST_PATH=/app/model-manifest.json
x_gemini_key=
x_openrouter_key=
NVIDIA_API_KEY=
OPENROUTER_MODEL=google/gemini-2.0-flash-001
```

| Variable | Rule |
| --- | --- |
| `MODEL_SIGNING_SECRET` | Server-only; same value for both replicas. Keep it during ordinary updates. Rotation invalidates outstanding links. |
| `MODEL_PUBLIC_ORIGIN` | `https://` followed by exactly your `APP_HOSTNAME`; no API path. |
| `MODEL_MANIFEST_PATH` | Container path `/app/model-manifest.json`; Compose mounts the app's shared manifest there. |
| `FIREBASE_PROJECT_ID` | Match the app; in production the value from **deploy/.env overrides** the value in microservice/.env. |
| Provider keys | Leave all three empty so the server cannot spend an operator's provider quota. |

No Firebase service-account JSON is needed. Verification uses public signing
keys. No Hugging Face token belongs in either server environment file. Keep the
secret file out of Git and copy it securely when moving or restoring the VM.

Do not rerun the `cp` commands over your configured files during an update.
Compose's `environment` entries take precedence over `env_file` values.
[Compose environment precedence](https://docs.docker.com/compose/how-tos/environment-variables/envvars-precedence/).

Load **only your trusted deployment file** for the bootstrap script, then
validate Compose without displaying the resolved secrets:

```sh
cd /opt/void_factor/deploy
set -a
. ./.env
set +a
/usr/local/bin/docker-compose -f docker-compose.prod.yml config --quiet
```

## 7. Build the API and stage the model

```sh
cd /opt/void_factor/deploy
/usr/local/bin/docker-compose -f docker-compose.prod.yml build microservice-1
install -d -m 0755 /srv/void-factor/models /srv/void-factor/model-staging
chown ubuntu:ubuntu /srv/void-factor/model-staging
```

Obtain the model once on an authorized workstation after accepting its upstream
terms. Use the exact repository, revision and filename in
[`assets/models/gemma3_1b_q4.json`](../assets/models/gemma3_1b_q4.json):

- Repository: `litert-community/Gemma3-1B-IT`.
- Revision: `2ad0cdf5e31fd96eaa08cc6a3242539461e5a42f`.
- File: `Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm`.

**On your laptop**, transfer the acquired file into the staging directory:

```sh
scp -i "$VF_OCI_KEY" /path/to/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm \
  "ubuntu@$VF_OCI_IP:/srv/void-factor/model-staging/"
```

**On the VM**, use the built image to verify and publish it. This avoids
installing a second Python dependency environment on the host:

```sh
docker run --rm --user 0:0 --entrypoint python \
  -v /opt/void_factor/assets/models/gemma3_1b_q4.json:/app/model-manifest.json:ro \
  -v /srv/void-factor/model-staging:/staging:ro \
  -v /srv/void-factor/models:/models \
  void-factor-microservice:latest \
  -m tools.stage_model \
  --manifest /app/model-manifest.json \
  --source /staging/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm \
  --model-root /models
```

The command must succeed: it streams the exact size and SHA-256 checks, then
atomically publishes `/srv/void-factor/models/<sha256>/<filename>` as read-only.
A mismatch stops publication. Nginx sees only this verified model root, mounted
read-only. Preserve directory traversal/read permissions for the Nginx worker.
The actual upstream bytes have not been acquired or independently verified in
the local implementation work; this step establishes that check.

If you deliberately configured another `MODEL_DIRECTORY`, replace
`/srv/void-factor/models` consistently in the directory and mount commands.
The staging copy can be removed after successful verification. See the
[download contract](../docs/model-download-contract.md) for the exact API behavior.

## 8. Bootstrap TLS

Keep the trusted deployment variables loaded from step 6. On a **first install**,
test in a separate Compose project so an untrusted staging certificate cannot
be retained in the production certificate volume:

```sh
cd /opt/void_factor/deploy
COMPOSE_PROJECT_NAME=voidfactor-staging STAGING=1 sh bootstrap-tls.sh
curl -kfsS "https://$APP_HOSTNAME/health"
/usr/local/bin/docker-compose -p voidfactor-staging -f docker-compose.prod.yml down -v
```

That `down -v` removes **only the disposable staging project's volumes**.
Do not use it with the production project. The staging run must be stopped
before production starts because both bind ports 80/443. Staging certificates
are intentionally untrusted; `-k` is only for that staging health check.
[Let's Encrypt staging environment](https://letsencrypt.org/docs/staging-environment/).

Then obtain the production certificate and start the production stack:

```sh
sh bootstrap-tls.sh
/usr/local/bin/docker-compose -f docker-compose.prod.yml ps
/usr/local/bin/docker-compose -f docker-compose.prod.yml exec nginx nginx -t
curl -fsS "https://$APP_HOSTNAME/health"
sh verify-live.sh "$APP_HOSTNAME"
```

The trusted `/health` request should return `{"status":"healthy"}`. Run
`sh deploy/verify-live.sh YOUR_HOSTNAME` **from your laptop too**; this checks the
external DNS/firewall/TLS path. The script checks scan authentication; test
model downloads separately below. Keep port 80 open for webroot renewal.

## 9. Verify the model environment and public download

First check both replicas' model configuration without revealing the secret:

```sh
cd /opt/void_factor/deploy
for service in microservice-1 microservice-2; do
  /usr/local/bin/docker-compose -f docker-compose.prod.yml exec -T "$service" python -c \
    'from app.models import load_artifact, signing_configuration; a=load_artifact(); _,origin=signing_configuration(); print(a.version, a.size_bytes, origin)'
done
```

Both should print the same version, size and HTTPS origin. This checks the
manifest and signing settings; `/health` alone does not.

For an end-to-end check, obtain a **Firebase ID token and matching uid** from
your signed-in test account. In your app debugger you can evaluate
`FirebaseAuth.instance.currentUser!.getIdToken()` and
`FirebaseAuth.instance.currentUser!.uid`; do not add token-printing to app logs.
Use a fresh ID token, not an OAuth access token or Firebase custom token.

In the VM administrator shell, with `APP_HOSTNAME` still loaded:

```sh
read -r -s -p 'Firebase ID token: ' VF_TEST_TOKEN
printf '\n'
read -r -p 'Matching uid: ' VF_TEST_UID
export VF_TEST_TOKEN VF_TEST_UID
cd /opt/void_factor
python3 - <<'PY'
import json, os, urllib.error, urllib.request
from pathlib import Path
base = 'https://' + os.environ['APP_HOSTNAME']
manifest = json.loads(Path('assets/models/gemma3_1b_q4.json').read_text())
request = urllib.request.Request(base + '/api/v1/models/gemma/download-link',
    data=json.dumps({'accepted_terms_version': manifest['terms_version']}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['VF_TEST_TOKEN'],
             'X-User-Id': os.environ['VF_TEST_UID'], 'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        link = json.load(response)
    assert link['model'] == manifest, 'manifest mismatch'
    with urllib.request.urlopen(urllib.request.Request(link['url'], method='HEAD'), timeout=30) as response:
        assert response.status == 200
        assert int(response.headers['Content-Length']) == manifest['size_bytes']
        assert response.headers.get('ETag')
    with urllib.request.urlopen(urllib.request.Request(link['url'],
            headers={'Range': 'bytes=0-1023'}), timeout=30) as response:
        assert response.status == 206
        assert response.headers['Content-Range'].startswith('bytes 0-1023/')
        assert len(response.read()) == 1024
    print('PASS: authenticated link, matching manifest, HEAD and byte range')
except urllib.error.HTTPError as error:
    raise SystemExit('HTTP ' + str(error.code) + ' — check configuration/auth/rate limits')
except Exception as error:
    raise SystemExit('Check failed: ' + type(error).__name__)
PY
unset VF_TEST_TOKEN VF_TEST_UID
```

The script never prints the reusable signed URL or token. Accept the displayed
Gemma terms before testing a download; the accepted version sent above comes
from the pinned manifest. Missing/invalid signing configuration returns 503,
invalid links return 403, and limits return 429 with `Retry-After: 10`.

## 10. Start on boot and point the app at the host

```sh
cd /opt/void_factor/deploy
cp voidfactor.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now voidfactor
systemctl status voidfactor --no-pager
```

The unit's working directory and environment file are `/opt/void_factor/deploy`;
its Compose executable is the wrapper installed in step 3.

**On your laptop**, build against the same HTTPS origin:

```sh
flutter build apk --release --target-platform android-arm64 \
  --dart-define=FOOD_API_BASE_URL=https://YOUR_HOSTNAME
```

For Play use `flutter build appbundle` with the same flags. The APK carries the
engine; Play bundles retain the on-demand engine module. Test one real model
download, app termination/restart, offline inference, and removal on Android
before distributing the app. Firestore rules, upload signing and publication
of the updated privacy policy remain separate release steps.

## Operations and troubleshooting

After copying/pulling updated code, rebuild and recreate the containers, then
reload Nginx so it immediately resolves the replicas' current addresses:

```sh
cd /opt/void_factor/deploy
systemctl reload voidfactor
/usr/local/bin/docker-compose -f docker-compose.prod.yml exec nginx nginx -s reload
sh verify-live.sh "$APP_HOSTNAME"
/usr/local/bin/docker-compose -f docker-compose.prod.yml run --rm --entrypoint certbot certbot renew --dry-run
```

The explicit Certbot entrypoint runs the one-shot dry-run rather than the
sidecar's renewal loop. Scheduled renewal checks run twice daily; Nginx reloads
every six hours. Preserve the production certificate volumes and signing
secret across updates. If changing hostname, update both environment files,
reload your shell variables, rerun TLS bootstrap and rebuild the app.

| Symptom | Check |
| --- | --- |
| Public connection times out | DNS/public IP, internet-gateway route, OCI ingress, VM INPUT/FORWARD rules |
| TLS fails | Correct A/AAAA records, production certificate, port 80 challenge path |
| `auth:` 503 | Effective Firebase project in deploy/.env; replicas reachable |
| Link issuance 503 | Secret length, HTTPS public origin, shared manifest mount; recreate replicas after env edits |
| Link issuance 401 | Fresh Firebase ID token and exact matching uid |
| Link issuance 409 | App's displayed terms version must match the server manifest |
| Download 403 | Expired/altered link, version/path mismatch, or replicas using different secrets |
| Download 404 | Artifact missing under `<MODEL_DIRECTORY>/<sha256>/<filename>` |
| Download 429 | Wait at least the returned Retry-After; close excess concurrent transfers |
| Disk fills | `df -h`, `docker system df`, logs/build cache/staging copies; preserve live certificate volumes |

After a request from your laptop, inspect Nginx's safe access logs:

```sh
/usr/local/bin/docker-compose -f docker-compose.prod.yml logs --tail=20 nginx
```

The client address should be your public IP. Private bridge addresses bypass
the edge's per-address limit; verified per-user limits still apply. Model logs
contain response body bytes, with query strings and credentials excluded.

Oracle currently includes **10 TB/month outbound data**. Model transfers share
that allowance with other egress; rate/concurrency limits do not enforce a
monthly byte cap. Monitor OCI usage and retain bandwidth totals. Idle Always
Free instances can be reclaimed, so keep a recoverable copy of your environment
secret, artifact source and certificate volumes.
[Oracle's transfer allowance and idle-resource policy](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).
