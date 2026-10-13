# Optional home worker. CUDA 12 + cuDNN 9 runtime, as faster-whisper (CTranslate2 4.x) expects.
# On a Mac, skip Docker for this part: Docker cannot reach Apple GPUs, so run worker.py natively.
FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 HF_HOME=/models

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py .

RUN useradd --system --uid 10001 dawwen && mkdir -p /models && chown dawwen /models
USER 10001
CMD ["python", "worker.py"]
