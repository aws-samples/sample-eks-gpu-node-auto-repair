"""Distributed LoRA fine-tune of Qwen2.5-1.5B-Instruct with checkpoint/resume.

Runs under torchrun (one process per GPU/node). Checkpoints to a shared FSx
directory every N steps; on start, resumes from the latest complete checkpoint.
"""
import argparse
import os

import torch
from datasets import load_dataset
from peft import LoraConfig, get_peft_model
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    DataCollatorForLanguageModeling,
    Trainer,
    TrainingArguments,
)

from checkpoint import find_latest_checkpoint

MODEL_ID = "Qwen/Qwen2.5-1.5B-Instruct"
DATASET_ID = "nvidia/HelpSteer2"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--output-dir", default="/fsx/checkpoints")
    p.add_argument("--max-steps", type=int, default=400)
    p.add_argument("--save-steps", type=int, default=50)
    p.add_argument("--logging-steps", type=int, default=5)
    p.add_argument("--per-device-batch-size", type=int, default=1)
    p.add_argument("--grad-accum", type=int, default=8)
    p.add_argument("--max-seq-len", type=int, default=1024)
    p.add_argument("--lr", type=float, default=2e-4)
    p.add_argument("--num-samples", type=int, default=4000)
    return p.parse_args()


def format_example(ex):
    instruction = ex["prompt"].strip()
    response = ex["response"].strip()
    prompt = f"### Instruction:\n{instruction}\n\n### Response:\n"
    return {"text": prompt + response}


def main():
    args = parse_args()
    is_rank0 = os.environ.get("RANK", "0") == "0"

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.bfloat16,
    )
    model.config.use_cache = False

    lora = LoraConfig(
        r=16,
        lora_alpha=32,
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    )
    model = get_peft_model(model, lora)
    if is_rank0:
        model.print_trainable_parameters()

    ds = load_dataset(DATASET_ID, split="train")
    ds = ds.select(range(min(args.num_samples, len(ds))))
    ds = ds.map(format_example, remove_columns=ds.column_names)

    def tokenize(batch):
        out = tokenizer(
            batch["text"],
            truncation=True,
            max_length=args.max_seq_len,
            padding="max_length",
        )
        return out

    ds = ds.map(tokenize, batched=True, remove_columns=["text"])

    collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)

    targs = TrainingArguments(
        output_dir=args.output_dir,
        max_steps=args.max_steps,
        per_device_train_batch_size=args.per_device_batch_size,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        logging_steps=args.logging_steps,
        save_steps=args.save_steps,
        save_total_limit=3,
        bf16=True,
        ddp_find_unused_parameters=False,
        report_to=[],
        # torchrun sets LOCAL_RANK/RANK/WORLD_SIZE; Trainer picks these up.
    )

    trainer = Trainer(
        model=model,
        args=targs,
        train_dataset=ds,
        data_collator=collator,
    )

    latest = find_latest_checkpoint(args.output_dir)
    if latest is not None:
        if is_rank0:
            print(f"[resume] Resuming from checkpoint {latest}", flush=True)
        trainer.train(resume_from_checkpoint=latest)
    else:
        if is_rank0:
            print("[resume] No checkpoint found; starting fresh from step 0", flush=True)
        trainer.train()

    if is_rank0:
        trainer.save_model(os.path.join(args.output_dir, "final"))
        print("[done] Training complete", flush=True)


if __name__ == "__main__":
    main()
