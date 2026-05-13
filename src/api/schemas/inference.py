from typing import Any, Optional
from pydantic import BaseModel, Field


class InferenceInput(BaseModel):
    name: str
    data: Any
    shape: Optional[list[int]] = None
    datatype: Optional[str] = "FP32"


class InferenceOutput(BaseModel):
    name: str
    data: Any
    shape: Optional[list[int]] = None
    datatype: Optional[str] = None


class InferenceRequest(BaseModel):
    model_name: str = Field(..., description="Name of the model to run inference on")
    model_version: str = Field(default="latest", description="Model version")
    inputs: list[InferenceInput]
    parameters: Optional[dict[str, Any]] = None


class InferenceResponse(BaseModel):
    model_name: str
    model_version: str
    outputs: list[InferenceOutput]


class ModelInfo(BaseModel):
    name: str
    version: str
    status: str
    framework: Optional[str] = None
    input_schema: Optional[dict] = None
    output_schema: Optional[dict] = None


class ModelListResponse(BaseModel):
    models: list[ModelInfo]
