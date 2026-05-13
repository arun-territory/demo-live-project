import pytest
import asyncio
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../src/api"))

from model_server.model_loader import EchoModel, ModelLoader
from schemas.inference import InferenceInput


@pytest.mark.asyncio
async def test_echo_model_predict():
    model = EchoModel(name="echo", version="1.0.0", framework="stub")
    inputs = [
        InferenceInput(name="x", data=[1.0, 2.0], shape=[2], datatype="FP32"),
        InferenceInput(name="y", data=[[0, 1], [2, 3]], shape=[2, 2], datatype="INT32"),
    ]
    outputs = await model.predict(inputs)
    assert len(outputs) == 2
    assert outputs[0].name == "x"
    assert outputs[0].data == [1.0, 2.0]
    assert outputs[1].name == "y"


@pytest.mark.asyncio
async def test_echo_model_empty_inputs():
    model = EchoModel(name="echo", version="1.0.0", framework="stub")
    outputs = await model.predict([])
    assert outputs == []


def test_model_loader_stub(tmp_path):
    loader = ModelLoader()
    loader.model_store = str(tmp_path / "nonexistent")
    registry = {}
    loader.discover_and_load(registry)
    assert "echo:1.0.0" in registry
    assert "echo:latest" in registry
    assert registry["echo:latest"]["status"] == "ready"


def test_model_loader_from_store(tmp_path):
    model_dir = tmp_path / "resnet50" / "1.0.0"
    model_dir.mkdir(parents=True)
    config = model_dir / "config.json"
    config.write_text('{"framework": "onnx"}')

    loader = ModelLoader()
    loader.model_store = str(tmp_path)
    registry = {}
    loader.discover_and_load(registry)

    assert "resnet50:1.0.0" in registry
    assert registry["resnet50:1.0.0"]["framework"] == "onnx"
    assert registry["resnet50:latest"] is registry["resnet50:1.0.0"]
