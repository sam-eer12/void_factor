import hashlib

import pytest
from app.models import ModelArtifact
from tools.stage_model import stage


@pytest.fixture
def artifact():
    return ModelArtifact(version='fixture-v1', filename='fixture.litertlm',
        source_repository='local/fixture', source_revision='a'*40,
        size_bytes=3, sha256=hashlib.sha256(b'abc').hexdigest(), terms_version='2026-04-01')


def test_stage_verified_file_is_atomic_and_immutable(tmp_path, artifact):
    source = tmp_path / 'acquired'
    source.write_bytes(b'abc')
    path = stage(source, tmp_path / 'models', artifact)
    assert path.read_bytes() == b'abc'
    assert path.parent.name == artifact.sha256
    assert path.stat().st_mode & 0o222 == 0
    before = path.stat().st_mtime_ns
    assert stage(source, tmp_path / 'models', artifact) == path
    assert path.stat().st_mtime_ns == before
    assert not list(path.parent.glob('.staging-*'))


@pytest.mark.parametrize('content', [b'ab', b'abcd', b'abd'])
def test_unverified_artifact_is_never_published(tmp_path, artifact, content):
    source = tmp_path / 'acquired'
    source.write_bytes(content)
    with pytest.raises(ValueError):
        stage(source, tmp_path / 'models', artifact)
    assert not list((tmp_path / 'models').rglob('*.litertlm'))
    assert not list((tmp_path / 'models').rglob('.staging-*'))
