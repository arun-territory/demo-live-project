import logging
import threading
from typing import Optional

from model_server.model_loader import ModelLoader
from schemas.inference import InferenceInput, InferenceOutput, ModelInfo

logger = logging.getLogger(__name__)


class ModelServer:
    _instance = None
    _lock = threading.Lock()

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        self._models: dict[str, dict] = {}
        self._loader = ModelLoader()
        self._ready = False
        self._initialized = True
        self._load_default_models()

    def _load_default_models(self):
        try:
            self._loader.discover_and_load(self._models)
            self._ready = True
            logger.info("ModelServer ready with %d models", len(self._models))
        except Exception:
            logger.exception("Failed to load default models")
            self._ready = False

    def get_model(self, name: str, version: str = "latest"):
        key = f"{name}:{version}"
        if key not in self._models:
            key = f"{name}:latest"
        return self._models.get(key)

    def list_models(self) -> list[ModelInfo]:
        result = []
        for key, entry in self._models.items():
            name, version = key.split(":", 1)
            result.append(
                ModelInfo(
                    name=name,
                    version=version,
                    status=entry.get("status", "unknown"),
                    framework=entry.get("framework"),
                )
            )
        return result

    def unload_model(self, name: str, version: str) -> bool:
        key = f"{name}:{version}"
        if key not in self._models:
            return False
        del self._models[key]
        logger.info("Unloaded model %s", key)
        return True

    def is_ready(self) -> bool:
        return self._ready
