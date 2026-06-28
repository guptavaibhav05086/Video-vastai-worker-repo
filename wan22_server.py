"""
Wan2.2 14B Image-to-Video FastAPI server — Apache 2.0 fallback.

Use this when HunyuanVideo-1.5 license is a concern.
Quality: VBench 86.22% (outperforms Kling on benchmarks).
Speed: ~3-5 min per 5-second clip on RTX 4090.
Cost: ~₹30.60/min of video (vs ₹57.12/min for Kling).

Run on a Vast.ai RTX 4090 pod:
    uvicorn wan22_server:app --host 0.0.0.0 --port 8001

Then in CartoonAutomation .env:
    ANIMATION_BACKEND=wan22
    WAN22_API_URL=http://<pod-ip>:8001/generate
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

pipeline = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipeline
    print("[startup] Loading Wan2.2-I2V-14B-480P (FP8, ~24 GB VRAM)...")
    from diffusers import WanImageToVideoPipeline
    pipeline = WanImageToVideoPipeline.from_pretrained(
        "Wan-AI/Wan2.2-I2V-14B-480P",
        torch_dtype=torch.bfloat16,
    ).to("cuda")
    print("[startup] Wan2.2 14B ready.")
    yield
    del pipeline
    torch.cuda.empty_cache()

app = FastAPI(lifespan=lifespan)


class GenerateRequest(BaseModel):
    image: str
    prompt: str
    duration_seconds: int = 5


@app.get("/health")
def health():
    return {"status": "ok", "model": "Wan2.2-14B", "vram_free_gb": _free_vram()}


@app.post("/generate")
def generate(req: GenerateRequest) -> JSONResponse:
    if pipeline is None:
        raise HTTPException(503, "Model not loaded")

    try:
        header, b64_data = req.image.split(",", 1)
        pil_img = Image.open(io.BytesIO(base64.b64decode(b64_data))).convert("RGB")
    except Exception as exc:
        raise HTTPException(400, f"Invalid image data: {exc}")

    fps = 16
    num_frames = req.duration_seconds * fps

    logger.info("Wan2.2: generating %d-sec clip, %d frames: %s", req.duration_seconds, num_frames, req.prompt[:80])

    try:
        output = pipeline(
            image=pil_img,
            prompt=req.prompt,
            num_frames=num_frames,
            num_inference_steps=50,
        )
        frames = output.frames[0]
    except Exception as exc:
        logger.error("Generation failed: %s", exc)
        raise HTTPException(500, f"Generation failed: {exc}")

    buf = io.BytesIO()
    imageio.mimsave(buf, [frame for frame in frames], fps=fps, format="mp4",
                    output_params=["-vcodec", "libx264", "-pix_fmt", "yuv420p"])
    video_b64 = base64.b64encode(buf.getvalue()).decode()

    return JSONResponse({"video_base64": video_b64, "duration_seconds": req.duration_seconds, "fps": fps})


def _free_vram() -> float:
    if torch.cuda.is_available():
        free, _ = torch.cuda.mem_get_info()
        return round(free / 1e9, 1)
    return -1.0
