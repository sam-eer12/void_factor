"""What an upload actually is, decided from its bytes rather than its label.

The multipart part's declared Content-Type and filename are whatever the client
wrote: the Flutter app names every upload `meal.jpg` whatever the picker handed
it, and anything else can claim anything. The first few bytes of an image
format are fixed by its specification, so those are what decides.

The result matters twice. Bytes that are no image the providers read are
refused here, before a provider call is spent on them. And the detected type is
what the provider is told, so a PNG from the gallery is sent as a PNG rather
than mislabelled as the JPEG it was never.
"""
from fastapi import HTTPException, UploadFile

# Under nginx's 12m client_max_body_size, which bounds the whole multipart body
# including the part headers and boundary. Checked here as well because the
# service does not assume it is only ever reached through the proxy.
MAX_IMAGE_BYTES = 10 * 1024 * 1024

JPEG = "image/jpeg"
PNG = "image/png"
WEBP = "image/webp"
HEIC = "image/heic"
HEIF = "image/heif"

# Everything any provider here reads. Gemini takes all five; the
# OpenAI-compatible providers take the first three (see ACCEPTED_BY_OPENAI_COMPATIBLE).
SUPPORTED = (JPEG, PNG, WEBP, HEIC, HEIF)

# The OpenAI image_url contract covers JPEG, PNG, WebP and GIF. HEIC is an
# iPhone camera format that Gemini reads natively and these do not.
ACCEPTED_BY_OPENAI_COMPATIBLE = (JPEG, PNG, WEBP)

# ISO base media file brands (the four bytes after `ftyp`) that mark an
# HEVC-coded image, and those that mark the generic HEIF container.
_HEIC_BRANDS = {b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis"}
_HEIF_BRANDS = {b"mif1", b"msf1", b"heif"}


def sniff(data: bytes) -> str | None:
    """The image type [data] starts like, or None when it is none of ours."""
    if data.startswith(b"\xff\xd8\xff"):
        return JPEG
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return PNG
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return WEBP
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brand = data[8:12]
        if brand in _HEIC_BRANDS:
            return HEIC
        if brand in _HEIF_BRANDS:
            return HEIF
    return None


async def read_image(upload: UploadFile) -> tuple[bytes, str]:
    """The upload's bytes and its sniffed MIME type, or a 4xx saying why not.

    Reads one byte past the cap rather than the whole part, so an oversized
    upload costs at most the cap in memory before it is refused.

    Every detail starts `image:` so the client can tell a rejected photo from a
    rejected key or session without parsing prose.
    """
    data = await upload.read(MAX_IMAGE_BYTES + 1)
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="image: too large")
    if not data:
        raise HTTPException(status_code=400, detail="image: empty upload")
    mime = sniff(data)
    if mime is None:
        raise HTTPException(status_code=415, detail="image: unrecognised format")
    return data, mime


def require_one_of(mime: str, accepted: tuple[str, ...]) -> None:
    """Refuses a real image the chosen provider cannot read.

    A 415 like an unrecognised upload, but with its own detail: the photo is
    fine and a different provider could take it, which is a different next step
    for the user than a file that is not a photo at all.
    """
    if mime not in accepted:
        raise HTTPException(
            status_code=415, detail="image: format not supported by this provider"
        )
