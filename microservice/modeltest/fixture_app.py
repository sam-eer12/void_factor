"""Only used by the local edge test: real auth, with a throwaway public key."""
import os
from pathlib import Path
from cryptography.hazmat.primitives.serialization import load_pem_public_key
from app import auth
from app.main import create_app

key = load_pem_public_key(Path(os.environ['FIXTURE_PUBLIC_KEY']).read_bytes())
auth.signing_key_for = lambda token: key
app = create_app()
