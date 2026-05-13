import os
import logging
from typing import Any

logger = logging.getLogger(__name__)

MODEL_STORE_ENV = "MODEL_STORE_PATH"
DEFAULT_MODEL_STORE = "/models"


class BaseModel:
    def __init__(self, name: str, version: str, framework: str):
        self.name = name
        self.version = version
        self.framework = framework

    async def predict(self, inputs: list) -> list:
        raise NotImplementedError


class EchoModel(BaseModel):
    """Stub model that echoes inputs — used for smoke-testing."""

    async def predict(self, inputs: list) -> list:
        from schemas.inference import InferenceOutput

        return [InferenceOutput(name=inp.name, data=inp.data, shape=inp.shape) for inp in inputs]


class ModelLoader:
    def __init__(self):
        self.model_store = os.environ.get(MODEL_STORE_ENV, DEFAULT_MODEL_STORE)

    def discover_and_load(self, registry: dict[str, Any]):
        if not os.path.isdir(self.model_store):
            logger.warning("Model store '%s' not found — loading stub model", self.model_store)
            self._load_stub(registry)
            return

        loaded = 0
        for model_name in os.listdir(self.model_store):
            model_dir = os.path.join(self.model_store, model_name)
            if not os.path.isdir(model_dir):
                continue
            for version in os.listdir(model_dir):
                version_dir = os.path.join(model_dir, version)
                if not os.path.isdir(version_dir):
                    continue
                try:
                    model = self._load_model(model_name, version, version_dir)
                    registry[f"{model_name}:{version}"] = {
                        "model": model,
                        "status": "ready",
                        "framework": model.framework,
                    }
                    registry[f"{model_name}:latest"] = registry[f"{model_name}:{version}"]
                    loaded += 1
                    logger.info("Loaded model %s:%s from %s", model_name, version, version_dir)
                except Exception:
                    logger.exception("Failed to load model %s:%s", model_name, version)

        if loaded == 0:
            self._load_stub(registry)

    def _load_model(self, name: str, version: str, path: str) -> BaseModel:
        config_path = os.path.join(path, "config.json")
        if os.path.exists(config_path):
            import json

            with open(config_path) as f:
                config = json.load(f)
            framework = config.get("framework", "unknown")
        else:
            framework = "unknown"

        return EchoModel(name=name, version=version, framework=framework)

    def _load_stub(self, registry: dict):
        stub = EchoModel(name="echo", version="1.0.0", framework="stub")
        registry["echo:1.0.0"] = {"model": stub, "status": "ready", "framework": "stub"}
        registry["echo:latest"] = registry["echo:1.0.0"]
        logger.info("Loaded stub echo model")
