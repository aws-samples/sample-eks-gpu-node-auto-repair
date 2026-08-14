"""Full-parameter FSDP fine-tune of Qwen2.5-32B-Instruct with DCP sharded checkpoints.

Runs under torchrun (8 procs/node x 2 nodes = 16 ranks). Shards params+grads+optimizer
across all ranks (FSDP full shard), checkpoints to a shared FSx dir with
torch.distributed.checkpoint every --save-steps, and resumes from the latest complete
checkpoint on restart (this is what makes node auto-repair non-destructive to progress).
"""
import argparse
import functools
import os

import torch
import torch.distributed as dist
import torch.distributed.checkpoint as dcp
from datasets import load_dataset
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP
from torch.distributed.fsdp import ShardingStrategy
from torch.distributed.fsdp.wrap import transformer_auto_wrap_policy
from torch.distributed.checkpoint.state_dict import (
    get_state_dict,
    set_state_dict,
)
from torch.utils.data import DataLoader, DistributedSampler
from transformers import AutoModelForCausalLM, AutoTokenizer
from transformers.models.qwen2.modeling_qwen2 import Qwen2DecoderLayer

from checkpoint_dcp import find_latest_dcp_checkpoint

MODEL_ID = "Qwen/Qwen2.5-32B-Instruct"
DATASET_ID = "nvidia/HelpSteer2"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--output-dir", default="/fsx/checkpoints")
    p.add_argument("--max-steps", type=int, default=2000)
    p.add_argument("--save-steps", type=int, default=50)
    p.add_argument("--logging-steps", type=int, default=5)
    p.add_argument("--per-device-batch-size", type=int, default=1)
    p.add_argument("--max-seq-len", type=int, default=2048)
    p.add_argument("--lr", type=float, default=1e-5)
    p.add_argument("--num-samples", type=int, default=8000)
    return p.parse_args()


def format_example(ex):
    instruction = ex["prompt"].strip()
    response = ex["response"].strip()
    prompt = f"### Instruction:\n{instruction}\n\n### Response:\n"
    return prompt + response


def main():
    args = parse_args()
    dist.init_process_group("nccl")
    rank = dist.get_rank()
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    is_rank0 = rank == 0

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(MODEL_ID, torch_dtype=torch.bfloat16)
    model.config.use_cache = False

    wrap_policy = functools.partial(
        transformer_auto_wrap_policy, transformer_layer_cls={Qwen2DecoderLayer}
    )
    model = FSDP(
        model,
        sharding_strategy=ShardingStrategy.FULL_SHARD,
        auto_wrap_policy=wrap_policy,
        device_id=torch.cuda.current_device(),
        use_orig_params=True,
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)

    ds = load_dataset(DATASET_ID, split="train")
    ds = ds.select(range(min(args.num_samples, len(ds))))

    def collate(batch):
        texts = [format_example(b) for b in batch]
        enc = tokenizer(
            texts,
            return_tensors="pt",
            padding="max_length",
            truncation=True,
            max_length=args.max_seq_len,
        )
        enc["labels"] = enc["input_ids"].clone()
        return enc

    sampler = DistributedSampler(ds, num_replicas=dist.get_world_size(), rank=rank)
    loader = DataLoader(
        ds, batch_size=args.per_device_batch_size, sampler=sampler, collate_fn=collate
    )

    # Resume from the latest complete DCP checkpoint, if any.
    start_step = 0
    latest = find_latest_dcp_checkpoint(args.output_dir)
    if latest is not None:
        model_sd, optim_sd = get_state_dict(model, optimizer)
        state = {"model": model_sd, "optim": optim_sd, "step": 0}
        dcp.load(state_dict=state, checkpoint_id=latest)
        set_state_dict(
            model, optimizer, model_state_dict=state["model"], optim_state_dict=state["optim"]
        )
        start_step = int(state.get("step", 0))
        if is_rank0:
            print(f"[resume] Resuming from {latest} at step {start_step}", flush=True)
    else:
        if is_rank0:
            print("[resume] No checkpoint found; starting fresh from step 0", flush=True)

    model.train()
    step = start_step
    # Note: on resume we restore weights/optimizer/step but do NOT fast-forward the DataLoader;
    # training *progress* is preserved (the point of the demo), data ordering is not bit-exact.
    data_iter = iter(loader)
    while step < args.max_steps:
        try:
            batch = next(data_iter)
        except StopIteration:
            sampler.set_epoch(step)
            data_iter = iter(loader)
            batch = next(data_iter)
        batch = {k: v.to(local_rank) for k, v in batch.items()}
        optimizer.zero_grad()
        out = model(**batch)
        out.loss.backward()
        optimizer.step()
        step += 1

        if is_rank0 and step % args.logging_steps == 0:
            print(f"step {step}/{args.max_steps} loss {out.loss.item():.4f}", flush=True)

        if step % args.save_steps == 0:
            model_sd, optim_sd = get_state_dict(model, optimizer)
            ckpt_dir = os.path.join(args.output_dir, f"step-{step}")
            dcp.save(
                state_dict={"model": model_sd, "optim": optim_sd, "step": step},
                checkpoint_id=ckpt_dir,
            )
            if is_rank0:
                print(f"[checkpoint] saved {ckpt_dir}", flush=True)

    if is_rank0:
        print("[done] Training complete", flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
