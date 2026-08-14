# PyTorch base with CUDA runtime matching L40S (Ada, sm_89) and torch 2.4.
FROM pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime

WORKDIR /workspace

# Install Python deps first for layer caching.
COPY requirements.txt /workspace/requirements.txt
RUN pip install --no-cache-dir -r /workspace/requirements.txt

# Copy training code.
COPY checkpoint.py /workspace/checkpoint.py
COPY train.py /workspace/train.py

# HuggingFace cache goes to the mounted FSx at runtime (set via env in the JobSet).
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "-m", "torch.distributed.run"]
