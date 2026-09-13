"""One throwaway RSA key, reused across processes.

The load generator mints tokens with the private half; the server under test
verifies them with the public half. Generating 2048-bit RSA takes long enough
that doing it per process would show up as a startup stall, so the key is cached
on disk and both sides load the same file.
"""
from pathlib import Path
from functools import lru_cache

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

KEY_PATH = Path(__file__).with_name(".loadtest_key.pem")

PROJECT_ID = "loadtest-project"
ISSUER = f"https://securetoken.google.com/{PROJECT_ID}"


@lru_cache(maxsize=1)
def private_key():
    if KEY_PATH.exists():
        return serialization.load_pem_private_key(KEY_PATH.read_bytes(), password=None)
    # 2048 is the smallest size Google uses, so verification costs what it costs
    # in production rather than less.
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    KEY_PATH.write_bytes(
        key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    KEY_PATH.chmod(0o600)
    return key


@lru_cache(maxsize=1)
def public_key():
    return private_key().public_key()
