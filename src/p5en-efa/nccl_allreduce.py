"""Standalone NCCL all-reduce bandwidth benchmark over EFA.

Launched with the SAME torchrun/JobSet rendezvous as the FSDP job (no MPI operator / SSH).
Each rank runs an all_reduce across increasing message sizes and rank 0 prints the achieved
bus bandwidth (busbw) in GB/s, mirroring the nccl-tests all_reduce_perf metric:
  algbw = size_bytes / time_s ; busbw = algbw * 2*(N-1)/N   (ring all-reduce factor)
High busbw over EFA confirms the fabric is active (a TCP fallback would be far lower).
"""
import os
import time

import torch
import torch.distributed as dist


def human(n):
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.0f}TB"


def main():
    dist.init_process_group("nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    is_rank0 = rank == 0

    if is_rank0:
        print(f"[nccl] world_size={world} — all_reduce busbw sweep", flush=True)
        print(f"{'size':>10} {'time_ms':>10} {'algbw_GB/s':>12} {'busbw_GB/s':>12}", flush=True)

    # 8 bytes .. 16 GiB, doubling.
    size = 8
    max_size = 16 * 1024**3
    factor = 2.0 * (world - 1) / world
    while size <= max_size:
        n = max(size // 4, 1)  # float32 elements
        t = torch.ones(n, dtype=torch.float32, device=local_rank)
        # warmup
        for _ in range(5):
            dist.all_reduce(t)
        torch.cuda.synchronize()
        iters = 20
        start = time.perf_counter()
        for _ in range(iters):
            dist.all_reduce(t)
        torch.cuda.synchronize()
        elapsed = (time.perf_counter() - start) / iters
        nbytes = n * 4
        algbw = nbytes / elapsed / 1e9
        busbw = algbw * factor
        if is_rank0:
            print(f"{human(nbytes):>10} {elapsed*1e3:>10.3f} {algbw:>12.2f} {busbw:>12.2f}", flush=True)
        size *= 2

    if is_rank0:
        print("[nccl] done", flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
