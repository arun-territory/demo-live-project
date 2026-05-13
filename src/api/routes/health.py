from fastapi import APIRouter
from model_server.server import ModelServer

router = APIRouter()
model_server = ModelServer()


@router.get("/healthz")
async def liveness():
    return {"status": "ok"}


@router.get("/readyz")
async def readiness():
    if model_server.is_ready():
        return {"status": "ready"}
    return {"status": "not_ready"}, 503
