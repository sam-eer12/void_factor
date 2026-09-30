from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import http_pool
from app.routes import router
from app.models import router as model_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # The providers share one outbound connection pool for the life of the
    # process. Nothing else owns it, so shutdown closes it here rather than
    # leaving sockets to a finalizer that may never run.
    await http_pool.aclose()


def create_app() -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    app.include_router(model_router)
    return app


app = create_app()
