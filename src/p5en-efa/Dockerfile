# AWS DLC PyTorch training image (EFA + aws-ofi-nccl + NCCL preinstalled).
# ${DLC_IMAGE} is substituted by image-build.sh (resolved from the regional DLC account).
ARG DLC_IMAGE
FROM ${DLC_IMAGE}

WORKDIR /workspace
# The DLC base already provides torch/CUDA/NCCL/EFA; install only the additive packages the
# training/benchmark scripts need. (src/p5en-efa/requirements.txt pins the full set for local unit
# tests; we deliberately do NOT reinstall torch here.)
RUN pip install --no-cache-dir "transformers==4.49.0" "datasets==3.2.0"

COPY checkpoint_dcp.py /workspace/checkpoint_dcp.py
COPY train_fsdp.py /workspace/train_fsdp.py
COPY nccl_allreduce.py /workspace/nccl_allreduce.py

ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-m", "torch.distributed.run"]
