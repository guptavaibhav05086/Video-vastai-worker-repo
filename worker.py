"""
Vast.ai Serverless PyWorker — HunyuanVideo-1.5 / Wan2.2 video generation.

This file is loaded automatically by Vast.ai Serverless after the model server
(hunyuan_server.py or wan22_server.py) is started by setup_pod.sh.

Deployment:
  1. Push this file + hunyuan_server.py + wan22_server.py + requirements_pod.txt
     to a public GitHub repo.
  2. In the Vast.ai Serverless endpoint config, set:
       PYWORKER_REPO=https://github.com/your-org/your-repo
       MODEL_SERVER_PORT=8000   (8000 for hunyuan, 8001 for wan22)
       MODEL_LOG_FILE=/workspace/model_server.log

How it works:
  - Vast.ai clones the repo and installs requirements_pod.txt
  - setup_pod.sh starts the FastAPI server in the background
  - This worker.py starts and proxies /generate and /health to the model server
  - When idle, the worker transitions to "Stopped" (no GPU charges, model stays loaded)
  - On next request, wakes up in seconds (no model re-download)

.env changes (local machine):
  ANIMATION_BACKEND=hunyuan
  HUNYUAN_VAST_ENDPOINT=cartoon-hunyuan   # name you gave the endpoint
  VAST_API_KEY=<your-vast-api-key>        # from cloud.vast.ai/account
"""
import os
from vastai import Worker, WorkerConfig, HandlerConfig, BenchmarkConfig, LogActionConfig

MODEL_PORT = int(os.environ.get("MODEL_SERVER_PORT", "8000"))
MODEL_LOG = os.environ.get("MODEL_LOG_FILE", "/workspace/model_server.log")

# Determines which model's startup message to wait for.
# Set MODEL_SERVER_PORT=8000 → HunyuanVideo-1.5
# Set MODEL_SERVER_PORT=8001 → Wan2.2 14B
_LOAD_SIGNALS = {
    8000: ["HunyuanVideo-1.5 ready"],
    8001: ["Wan2.2-14B ready"],
}
on_load = _LOAD_SIGNALS.get(MODEL_PORT, ["Application startup complete"])


def _video_workload(payload: dict) -> float:
    # Workload = frames to generate. Used by Vast.ai autoscaling to right-size capacity.
    return float(payload.get("duration_seconds", 5) * 24)


worker_config = WorkerConfig(
    model_server_url="http://127.0.0.1",
    model_server_port=MODEL_PORT,
    model_log_file=MODEL_LOG,
    handlers=[
        HandlerConfig(
            route="/generate",
            allow_parallel_requests=False,  # Video gen is VRAM-intensive; one at a time
            max_queue_time=600.0,           # 10-min queue timeout (clips can take 2-3 min)
            workload_calculator=_video_workload,
            benchmark_config=BenchmarkConfig(
                # Minimal benchmark: 1-second clip so readiness check completes quickly
                dataset=[{"duration_seconds": 1, "prompt": "benchmark test clip"}],
                runs=1,
                concurrency=1,
            ),
        ),
        HandlerConfig(
            route="/health",
            allow_parallel_requests=True,
            max_queue_time=10.0,
            workload_calculator=lambda _: 0.0,
        ),
    ],
    log_action_config=LogActionConfig(
        on_load=on_load,
        on_error=["CUDA out of memory", "RuntimeError:", "Traceback", "FATAL"],
        on_info=["Loading", "Downloading"],
    ),
)

Worker(worker_config).run()
