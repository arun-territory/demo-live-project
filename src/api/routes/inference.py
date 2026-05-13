import logging
from fastapi import APIRouter, HTTPException, BackgroundTasks
from schemas.inference import InferenceRequest, InferenceResponse, ModelListResponse
from model_server.server import ModelServer

logger = logging.getLogger(__name__)
router = APIRouter()
model_server = ModelServer()


@router.post("/infer", response_model=InferenceResponse)
async def run_inference(request: InferenceRequest, background_tasks: BackgroundTasks):
    """Run inference on a deployed model."""
    model = model_server.get_model(request.model_name, request.model_version)
    if model is None:
        raise HTTPException(
            status_code=404,
            detail=f"Model '{request.model_name}' version '{request.model_version}' not found",
        )
    try:
        outputs = await model.predict(request.inputs)
        background_tasks.add_task(
            logger.info,
            "Inference completed: model=%s version=%s",
            request.model_name,
            request.model_version,
        )
        return InferenceResponse(
            model_name=request.model_name,
            model_version=request.model_version,
            outputs=outputs,
        )
    except Exception as exc:
        logger.exception("Inference failed for model %s", request.model_name)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@router.get("/models", response_model=ModelListResponse)
async def list_models():
    """List all deployed models and their readiness status."""
    return ModelListResponse(models=model_server.list_models())


@router.delete("/models/{model_name}/{model_version}")
async def unload_model(model_name: str, model_version: str):
    """Unload a model from memory."""
    success = model_server.unload_model(model_name, model_version)
    if not success:
        raise HTTPException(status_code=404, detail="Model not found")
    return {"status": "unloaded", "model_name": model_name, "model_version": model_version}
