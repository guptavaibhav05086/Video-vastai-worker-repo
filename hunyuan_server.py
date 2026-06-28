"""
HunyuanVideo-1.5 Image-to-Video FastAPI server.

Run on a Vast.ai RTX 4090 pod:
    uvicorn hunyuan_server:app --host 0.0.0.0 --port 8000

Then in CartoonAutomation .env:
    ANIMATION_BACKEND=hunyuan
    HUNYUAN_API_URL=http://<pod-ip>:8000/generate

Request:
    POST /generate
    {"image": "data:image/png;base64,...", "prompt": "...", "duration_seconds": 5}

Response:
    {"video_base64": "<mp4-bytes-base64>", "duration_seconds": 5, "fps": 24}
"""

import io
import base64
import logging
from contextlib import asynccontextmanager

import torch
import imageio
from PIL import Image
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)

# ── Model loading ────────────────────────────────────────────────────────────
# HunyuanVideo-1.5 in FP8 / CPU-offload mode uses only ~9 GB active VRAM on RTX 4090.
# The remaining 15 GB is available for other tasks (kohya_ss runs after server shutdown).

pipeline = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipeline
    print("[startup] Loading HunyuanVideo-1.5 (FP8 mode, ~9 GB VRAM)...")
    from diffusers import HunyuanVideoImageToVideoPipeline
    pipeline = HunyuanVideoImageToVideoPipeline.from_pretrained(
        "tencent/HunyuanVideo-1.5",
        torch_dtype=torch.bfloat16,
    ).to("cuda")
    pipeline.enable_model_cpu_offload()
    pipeline.vae.enable_tiling()          # reduces peak VRAM during decode
    print("[startup] HunyuanVideo-1.5 ready.")
    yield
    print("[shutdown] Releasing model...")
    del pipeline
    torch.cuda.empty_cache()

app = FastAPI(lifespan=lifespan)


class GenerateRequest(BaseModel):
    image: str                    # data URL: "data:image/png;base64,..."
    prompt: str
    duration_seconds: int = 5


@app.get("/health")
def health():
    return {"status": "ok", "model": "HunyuanVideo-1.5", "vram_free_gb": _free_vram()}


@app.post("/generate")
def generate(req: GenerateRequest) -> JSONResponse:
    if pipeline is None:
        raise HTTPException(503, "Model not loaded")

    # Decode base64 image
    try:
        header, b64_data = req.image.split(",", 1)
        pil_img = Image.open(io.BytesIO(base64.b64decode(b64_data))).convert("RGB")
    except Exception as exc:
        raise HTTPException(400, f"Invalid image data: {exc}")

    fps = 24
    num_frames = req.duration_seconds * fps

    logger.info("Generating %d-sec clip (%d frames): %s", req.duration_seconds, num_frames, req.prompt[:80])

    try:
        output = pipeline(
            image=pil_img,
            prompt=req.prompt,
            num_frames=num_frames,
            num_inference_steps=50,
        )
        frames = output.frames[0]   # list of PIL Images
    except Exception as exc:
        logger.error("Generation failed: %s", exc)
        raise HTTPException(500, f"Generation failed: {exc}")

    # Encode frames to MP4
    buf = io.BytesIO()
    imageio.mimsave(buf, [frame for frame in frames], fps=fps, format="mp4",
                    output_params=["-vcodec", "libx264", "-pix_fmt", "yuv420p"])
    video_b64 = base64.b64encode(buf.getvalue()).decode()

    return JSONResponse({"video_base64": video_b64, "duration_seconds": req.duration_seconds, "fps": fps})


def _free_vram() -> float:
    if torch.cuda.is_available():
        free, total = torch.cuda.mem_get_info()
        return round(free / 1e9, 1)
    return -1.0
