"""Verify an already acquired artifact and atomically stage it for Nginx.

Run from microservice/: .venv/bin/python -m tools.stage_model --source PATH --model-root PATH
Acquisition is separate; this command never downloads weights or takes a token.
"""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile

from app.models import DEFAULT_MANIFEST, ModelArtifact


def verify(path: Path, artifact: ModelArtifact) -> bool:
    if not path.is_file() or path.stat().st_size != artifact.size_bytes:
        return False
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest() == artifact.sha256


def stage(source: Path, model_root: Path, artifact: ModelArtifact) -> Path:
    destination = model_root / artifact.sha256 / artifact.filename
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if not verify(destination, artifact):
            raise ValueError('Existing immutable artifact does not match the manifest')
        return destination
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.staging-', delete=False) as output:
            temporary = Path(output.name)
            digest = hashlib.sha256()
            count = 0
            with source.open('rb') as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b''):
                    count += len(chunk)
                    if count > artifact.size_bytes:
                        raise ValueError('Artifact exceeds manifest size')
                    digest.update(chunk)
                    output.write(chunk)
            if count != artifact.size_bytes or digest.hexdigest() != artifact.sha256:
                raise ValueError('Artifact size or SHA-256 does not match the manifest')
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(0o444)
        temporary.rename(destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return destination
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--model-root', required=True, type=Path)
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    artifact = ModelArtifact.model_validate_json(args.manifest.read_bytes())
    print(stage(args.source, args.model_root, artifact))


if __name__ == '__main__':
    main()
