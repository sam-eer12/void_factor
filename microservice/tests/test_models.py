import json
import time
from urllib.parse import parse_qsl, urlencode, urlsplit

import pytest
from fastapi.testclient import TestClient

from app import config, models
from app.main import app

client = TestClient(app)
ENDPOINT = '/api/v1/models/gemma/download-link'


@pytest.fixture
def model_config(monkeypatch, tmp_path):
    manifest = json.loads(models.DEFAULT_MANIFEST.read_text())
    path = tmp_path / 'manifest.json'
    path.write_text(json.dumps(manifest))
    monkeypatch.setattr(config, 'MODEL_MANIFEST_PATH', str(path))
    monkeypatch.setattr(config, 'MODEL_SIGNING_SECRET', 's' * 64)
    monkeypatch.setattr(config, 'MODEL_PUBLIC_ORIGIN', 'https://models.example.test')
    return manifest


def issue(headers):
    return client.post(ENDPOINT, headers=headers, json={'accepted_terms_version': '2026-04-01'})


def verify(url, method='GET'):
    parsed = urlsplit(url)
    return client.get('/internal/models/verify', headers={
        'X-Original-URI': f'{parsed.path}?{parsed.query}', 'X-Original-Method': method,
        'X-Verified-Uid': 'forged',
    })


def change(url, **updates):
    parsed = urlsplit(url)
    values = dict(parse_qsl(parsed.query))
    values.update(updates)
    return parsed._replace(query=urlencode(values)).geturl()


def test_link_contract_and_reusable_get_head(model_config, auth_headers):
    response = issue(auth_headers)
    assert response.status_code == 200
    assert response.headers['cache-control'] == 'no-store'
    body = response.json()
    assert body['model'] == model_config
    assert body['url'].startswith('https://models.example.test/models/' + model_config['sha256'] + '/')
    expiry = int(dict(parse_qsl(urlsplit(body['url']).query))['expires'])
    assert 86398 <= expiry - time.time() <= 86400
    for method in ['GET', 'HEAD', 'GET']:
        result = verify(body['url'], method)
        assert result.status_code == 204
        assert result.headers['x-verified-uid'] == 'u1'


def test_firebase_pair_is_required(model_config, auth_headers):
    assert issue({}).status_code == 401
    assert issue({**auth_headers, 'X-User-Id': 'other'}).status_code == 401


def test_current_terms_required(model_config, auth_headers):
    assert client.post(ENDPOINT, headers=auth_headers, json={
        'accepted_terms_version': 'old',
    }).status_code == 409
    assert client.post(ENDPOINT, headers=auth_headers, json={
        'accepted_terms_version': '2026-04-01', 'uid': 'forged',
    }).status_code == 422


@pytest.mark.parametrize('field,value', [
    ('uid', 'victim'), ('version', 'other'), ('expires', '9999999999'),
    ('signature', '0' * 64), ('signature', '☃'), ('expires', '-1'),
])
def test_each_signed_value_is_bound(model_config, auth_headers, field, value):
    url = issue(auth_headers).json()['url']
    assert verify(change(url, **{field: value})).status_code == 403


def test_path_and_method_are_bound(model_config, auth_headers):
    url = issue(auth_headers).json()['url']
    assert verify(url.replace('.litertlm', '.bin')).status_code == 403
    assert verify(url.replace('/models/', '/models/../models/')).status_code == 403
    assert verify(url, 'POST').status_code == 403


def test_duplicate_missing_and_extra_query_fields_rejected(model_config, auth_headers):
    url = issue(auth_headers).json()['url']
    assert verify(url + '&uid=u1').status_code == 403
    assert verify(url + '&extra=x').status_code == 403
    assert verify(url.split('?')[0]).status_code == 403


def test_expiry_boundary(model_config, auth_headers, monkeypatch):
    url = issue(auth_headers).json()['url']
    expires = int(dict(parse_qsl(urlsplit(url).query))['expires'])
    monkeypatch.setattr(models.time, 'time', lambda: expires - 1)
    assert verify(url).status_code == 204
    monkeypatch.setattr(models.time, 'time', lambda: expires)
    assert verify(url).status_code == 403


@pytest.mark.parametrize('name,value', [
    ('MODEL_SIGNING_SECRET', None), ('MODEL_SIGNING_SECRET', 'short'),
    ('MODEL_PUBLIC_ORIGIN', None), ('MODEL_PUBLIC_ORIGIN', 'https://u:p@host'),
    ('MODEL_PUBLIC_ORIGIN', 'http://public.example.test'),
    ('MODEL_PUBLIC_ORIGIN', 'https://host/path'),
    ('MODEL_MANIFEST_PATH', '/missing/model.json'),
])
def test_missing_or_unsafe_configuration_is_503(model_config, auth_headers, monkeypatch, name, value):
    monkeypatch.setattr(config, name, value)
    assert issue(auth_headers).status_code == 503
    assert verify('https://host/models/missing?x=y').status_code == 503


def test_invalid_manifest_is_503(model_config, auth_headers):
    path = config.MODEL_MANIFEST_PATH
    with open(path, 'w') as file:
        json.dump({**model_config, 'size_bytes': -1}, file)
    assert issue(auth_headers).status_code == 503


def test_configured_origin_ignores_host_and_forwarded_headers(model_config, auth_headers):
    response = issue({**auth_headers, 'Host': 'evil.test', 'X-Forwarded-Host': 'evil.test'})
    assert response.json()['url'].startswith('https://models.example.test/')


def test_separate_replicas_can_verify_same_link(model_config, auth_headers):
    url = issue(auth_headers).json()['url']
    with TestClient(app) as second:
        parsed = urlsplit(url)
        assert second.get('/internal/models/verify', headers={
            'X-Original-URI': parsed.path + '?' + parsed.query,
            'X-Original-Method': 'GET',
        }).status_code == 204
