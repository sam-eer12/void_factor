from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.providers import gemini
from app.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # The Gemini provider holds a connection pool to Google for the life of the
    # process. Nothing else owns it, so shutdown closes it here rather than
    # leaving sockets to a finalizer that may never run.
    await gemini.aclose()


def create_app() -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    return app


app = create_app()
