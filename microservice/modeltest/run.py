"""Exercise the shipped two-hop edge against real FastAPI and a 16 MiB fixture.

From the repo root: microservice/.venv/bin/python microservice/modeltest/run.py
Requires a running local Podman VM. Creates and removes its own isolated stack.
No cloud credentials or provider calls; no real model weights are required.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid
from urllib.parse import parse_qsl, urlencode, urlsplit

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ROOT = Path(__file__).resolve().parents[2]
NAME = 'vf-model-test-' + uuid.uuid4().hex[:8]
IMAGE = os.environ.get('MODEL_TEST_IMAGE', 'void-factor-microservice:latest')
created = []


def podman(*args):
    return subprocess.run(['podman', *args], check=True, capture_output=True, text=True).stdout.strip()


def run():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with tempfile.TemporaryDirectory(prefix=NAME, dir=ROOT / 'microservice/modeltest') as directory:
        temp = Path(directory)
        data = b'void-factor-fixture\n' * (16 * 1024 * 1024 // 19)
        manifest = {
            'version': 'gemma-test-v1', 'filename': 'fixture.litertlm',
            'source_repository': 'local/fixture', 'source_revision': 'a' * 40,
            'size_bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'terms_version': '2026-04-01',
        }
        artifact = temp / 'models' / manifest['sha256'] / manifest['filename']
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(data)
        (temp / 'manifest.json').write_text(json.dumps(manifest))
        (temp / 'key.pub').write_bytes(key.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo))
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        origin = f'http://127.0.0.1:{port}'
        podman('network', 'create', NAME)
        created.append(('network', NAME))
        api = NAME + '-api'
        podman('run', '-d', '--name', api, '--network', NAME, '--network-alias', 'microservice',
               '-v', f'{ROOT / "microservice/app"}:/app/app:ro',
               '-v', f'{ROOT / "microservice/modeltest"}:/app/modeltest:ro',
               '-v', f'{temp}:/fixtures:ro',
               '-e', 'FIREBASE_PROJECT_ID=model-fixture', '-e', 'MODEL_SIGNING_SECRET=' + 's' * 64,
               '-e', 'MODEL_PUBLIC_ORIGIN=' + origin, '-e', 'MODEL_MANIFEST_PATH=/fixtures/manifest.json',
               '-e', 'FIXTURE_PUBLIC_KEY=/fixtures/key.pub', IMAGE,
               'uvicorn', 'modeltest.fixture_app:app', '--host', '0.0.0.0', '--port', '8000', '--no-access-log')
        created.append(('container', api))
        edge = NAME + '-edge'
        podman('run', '-d', '--name', edge, '--network', NAME, '-p', f'127.0.0.1:{port}:80',
               '-v', f'{ROOT / "nginx/nginx.conf"}:/etc/nginx/nginx.conf:ro',
               '-v', f'{ROOT / "nginx/api_http.conf"}:/etc/nginx/api_http.conf:ro',
               '-v', f'{ROOT / "nginx/api_locations.conf"}:/etc/nginx/api_locations.conf:ro',
               '-v', f'{temp / "models"}:/srv/void-factor/models:ro',
               'nginx:alpine')
        created.append(('container', edge))
        client = httpx.Client(base_url=origin, timeout=10, trust_env=False)
        for _ in range(60):
            try:
                if client.get('/health').status_code == 200:
                    break
            except httpx.TransportError:
                pass
            time.sleep(0.25)
        else:
            raise AssertionError('local stack did not become healthy: ' + podman('logs', edge))

        def headers(uid):
            now = int(time.time())
            token = jwt.encode({'sub': uid, 'aud': 'model-fixture',
                'iss': 'https://securetoken.google.com/model-fixture', 'iat': now, 'exp': now + 3600}, key, algorithm='RS256')
            return {'Authorization': 'Bearer ' + token, 'X-User-Id': uid, 'X-Verified-Uid': 'victim'}

        def issue(uid):
            return client.post('/api/v1/models/gemma/download-link', headers=headers(uid),
                json={'accepted_terms_version': manifest['terms_version']})

        def link(uid):
            response = issue(uid)
            assert response.status_code == 200, response.text
            return response.json()['url']

        # Forged identities never reach the victim's link bucket.
        for _ in range(9):
            forged = {**headers('attacker'), 'X-User-Id': 'victim'}
            assert client.post('/api/v1/models/gemma/download-link', headers=forged,
                json={'accepted_terms_version': manifest['terms_version']}).status_code == 401
        assert issue('victim').status_code == 200
        url = link('transport')
        head = client.head(url)
        assert head.status_code == 200 and head.content == b''
        assert int(head.headers['content-length']) == len(data)
        assert 'content-encoding' not in head.headers
        full = client.get(url)
        assert full.status_code == 200 and full.content == data
        assert full.headers['etag'] == head.headers['etag']
        ranged = client.get(url, headers={'Range': 'bytes=31-95', 'If-Range': head.headers['etag']})
        assert ranged.status_code == 206 and ranged.content == data[31:96]
        assert ranged.headers['content-range'] == f'bytes 31-95/{len(data)}'
        assert client.post(url).status_code == 403
        assert client.get(url.replace('signature=', 'signature=0')).status_code == 403
        assert client.get(url, headers={'X-Original-URI': '/forged', 'X-Verified-Uid': 'forged'}).status_code == 200
        # Separate issue/download/food budgets, and independent accounts.
        for _ in range(7):
            assert issue('limited-links').status_code == 200
        limited = issue('limited-links')
        assert limited.status_code == 429 and limited.headers['retry-after'] == '10'
        assert issue('different-user').status_code == 200
        for _ in range(6):
            assert client.post('/api/not-a-provider', headers=headers('food')).status_code == 404
        assert client.post('/api/not-a-provider', headers=headers('food')).status_code == 429
        food_url = link('food')
        assert client.head(food_url).status_code == 200
        for _ in range(8):
            assert client.get(url.replace('signature=', 'signature=0'), headers={'X-Verified-Uid': 'transport'}).status_code == 403
        assert client.head(url).status_code == 200
        repeated = link('repeated')
        for _ in range(7):
            assert client.head(repeated).status_code == 200
        limited = client.head(link('repeated'))  # Renewing does not buy a fresh bucket.
        assert limited.status_code == 429 and limited.headers['retry-after'] == '10'
        assert client.head(link('another-user')).status_code == 200
        # A verifier's 503 must emerge as 503 rather than auth_request's 500.
        podman('stop', '--time', '1', api)
        unavailable = client.head(url)
        assert unavailable.status_code == 503, unavailable.status_code
        podman('start', api)
        podman('exec', edge, 'nginx', '-s', 'reload')
        for _ in range(40):
            if client.get('/health').status_code == 200:
                break
            time.sleep(0.1)
        # Two slow readers consume two slots for the verified user. A third is
        # rejected even with a fresh link; another account still downloads.
        slow_url = link('slow')
        parsed = urlsplit(slow_url)
        sockets = []
        try:
            for _ in range(2):
                sock = socket.socket()
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                sock.settimeout(5)
                sock.connect(('127.0.0.1', port))
                sock.sendall(f'GET {parsed.path}?{parsed.query} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'.encode())
                response = sock.recv(1024)
                assert b'200 OK' in response, response
                sockets.append(sock)
            time.sleep(0.2)
            third = client.head(link('slow'))
            assert third.status_code == 429 and third.headers['retry-after'] == '10', third
            assert client.head(link('not-slow')).status_code == 200
            files = podman('exec', edge, 'sh', '-c', 'find /var/cache/nginx -type f')
            assert not files, 'proxy spooled model bytes to disk: ' + files
        finally:
            for sock in sockets:
                sock.close()
        # Access/error logs may contain the artifact path, never capability queries.
        logs = podman('logs', edge)
        assert '?version=' not in logs and 'signature=' not in logs and 'Bearer ' not in logs
        client.close()
        print('PASS: real edge auth, identity isolation, separate limits, HEAD/GET/206, ETag, 2 transfers, 503 mapping, no buffering or signed-URL logs')


if __name__ == '__main__':
    try:
        run()
    finally:
        for kind, name in reversed(created):
            subprocess.run(['podman', 'rm', '-f', name] if kind == 'container' else ['podman', 'network', 'rm', name],
                           capture_output=True, check=False)
