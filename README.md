# sample-eks-gpu-node-auto-repair

Demonstrates how **Amazon EKS Auto Mode** natively self-heals a GPU node failure during a
distributed model-customization workload — using the **bundled EKS node monitoring agent** and
**node auto repair**, with nothing to install.

A GPU fault is injected mid-training; the node monitoring agent flips
`AcceleratedHardwareReady=False`, EKS node auto repair replaces the node via Karpenter, and a
JobSet-orchestrated fine-tune **auto-resumes from a checkpoint** on FSx for Lustre. You can then
pull a full node log bundle **without SSH** via the EKS-native `NodeDiagnostic` API
(`kubectl ekslogs`) — completing the EKS Auto Mode **detect → repair → diagnose** story.

## How it works

```
        +---------------------+
        |  GPU fault (XID 79) |
        +----------+----------+
                   | dcgmi --inject
                   v
   +-------------------------------+
   | Node monitoring agent (systemd)|  detects via DCGM push channel (sub-second)
   | sets AcceleratedHardwareReady  |----> False / NvidiaXID79Error
   +---------------+---------------+
                   | ~10-minute toleration
                   v
   +-------------------------------+
   | Karpenter node auto repair     |  cordons, drains, terminates, launches replacement
   +---------------+---------------+
                   | replacement node Ready (~90s)
                   v
   +-------------------------------+
   | JobSet failurePolicy: Recreate |  recreates the training gang
   +---------------+---------------+
                   v
   +-------------------------------+
   | trainer resumes from FSx       |  "[resume] Resuming from checkpoint checkpoint-N"
   | checkpoint; loss continues     |
   +-------------------------------+
```

1. The training JobSet runs one rank per node (pod anti-affinity), coordinated by `torchrun`,
   checkpointing to FSx for Lustre periodically.
2. A GPU fault is injected with `dcgmi test --inject` of a well-known XID on the rank-0 node —
   the node monitoring agent classifies it as **Fatal**.
3. The agent sets `AcceleratedHardwareReady=False`. After the **10-minute** toleration window,
   Karpenter node auto repair **replaces** the node.
4. JobSet's `restartStrategy: Recreate` recreates the training gang; the trainer resumes from the
   latest checkpoint — the log shows `[resume] Resuming from checkpoint …` and loss continues
   rather than restarting at 0.

| Phase | Duration |
|---|---|
| Detection (DCGM push channel) | sub-second |
| Toleration before repair (`AcceleratedHardwareReady`) | 10 minutes |
| Replacement node launch + register | ~90 seconds |
| **Total fault → workload running again** | **~12 minutes** |

The 10-minute toleration is a fixed EKS Auto Mode default and is not configurable. For the
service team's authoritative description of the toleration windows (10 min for accelerated
hardware, 30 min for kernel/runtime/networking/storage/kubelet) and the 20% fleet safety
threshold, see
[Under the hood: how Amazon EKS Auto Mode detects, repairs, and diagnoses node failures](https://aws.amazon.com/blogs/containers/under-the-hood-how-amazon-eks-auto-mode-detects-repairs-and-diagnoses-node-failures/)
and the [node health documentation](https://docs.aws.amazon.com/eks/latest/userguide/node-health.html).

> **Run pacing (important):** the training run must last longer than the full
> detect → 10-min toleration → replace cycle (~12 minutes), so the job is still running when node
> auto repair fires. The JobSet ships with `--max-steps=2000` for this reason. If training
> finishes first, the now-idle node is removed by Karpenter empty-consolidation *before* the
> repair Replace action triggers, and you won't see the repair/resume half in the same run.
> Inject the fault early in the run to leave plenty of runway afterward.

> **EKS 1.37 consolidation default:** Starting with EKS 1.37, newly created EKS Auto Mode
> NodePools that omit `consolidationPolicy` default to `Balanced` (approve a disruption when the
> hourly saving outweighs the Pod-disruption cost) instead of `WhenEmptyOrUnderutilized`. The GPU
> NodePools in this sample set `consolidationPolicy` **explicitly** (`WhenEmpty`), so they are
> unaffected by the default change — the run-pacing behavior above is unchanged. The new default
> only matters for NodePools that leave the field unset.

## Two paths

This repo ships two symmetric, self-contained paths. Pick based on the hardware you want to
show:

| Path | Instances | Workload | Networking | Make prefix | Manifests / scripts |
|---|---|---|---|---|---|
| **g6e** (entry-level) | 1× GPU per node, `g6e` / NVIDIA L40S | LoRA fine-tune of Qwen2.5-1.5B, JobSet `Recreate` | standard VPC CNI | `make g6e-*` | `kubernetes/g6e`, `scripts/g6e`, `terraform/g6e`, `src/g6e` |
| **p5en-efa** (large-scale) | 2× `p5en.48xlarge` (8× H200 each) | full-parameter FSDP fine-tune, JobSet `Recreate` | EFA / NCCL (16 EFA NICs) | `make p5en-efa-*` | `kubernetes/p5en-efa`, `scripts/p5en-efa`, `terraform/p5en-efa`, `src/p5en-efa` |

Both paths use the same self-healing primitives (node monitoring agent → node condition →
Karpenter Replace → JobSet gang-restart → checkpoint resume). The **g6e** path is the quickest,
cheapest way to see the full chain; the **p5en-efa** path additionally proves EFA bandwidth and
multi-node FSDP at scale.

> Validated end-to-end on **Amazon EKS Auto Mode, Kubernetes 1.36**:
> - **g6e** (`g6e.4xlarge` / L40S): fault injection → agent detection → node auto
>   repair → JobSet gang-restart → checkpoint resume.
> - **p5en-efa** (`p5en.48xlarge` / H200, platform `eks.9`): high-bandwidth NCCL
>   all-reduce over EFA, 16-rank FSDP, DCP checkpointing, XID detection, and the full hands-off repair + resume.
>
> See [How it works](#how-it-works) for the chain of events and timings.

The quickstart below uses the **g6e** path; substitute the `p5en-efa-` prefix for the
large-scale path.

## Prerequisites

- An AWS account with permissions for EKS, EC2 (g6e / p5en), FSx, ECR, CodeBuild, IAM, VPC.
- GPU quota in your region: `g6e` (L40S) for the g6e path, or `p5en` capacity for the
  p5en-efa path. For p5en, a **capacity reservation is strongly recommended** (ODCR or Capacity
  Block for ML).
- Local tools: `terraform >= 1.6`, `aws` CLI v2, `kubectl >= 1.30`, `helm >= 3.14`, `jq`,
  `envsubst` (gettext), `zip`. (No local Docker needed — images build via AWS CodeBuild.)

## Cost warning

This launches GPU instances, an FSx for Lustre filesystem, and an EKS control plane. The g6e
NodePool selects the `g6e` instance family and Karpenter picks the size (the validated run used
`g6e.4xlarge`, ~US$3/hr on-demand each in us-west-2). For the **g6e** path (2 GPU nodes + FSx
PERSISTENT_2 + control plane + NAT) expect roughly **US$6–8 per hour** (varies by region and the
size Karpenter selects). The **p5en-efa** path is substantially more expensive.
**Run `make g6e-clean` (or `make p5en-efa-clean`) when finished** to delete everything the path
created — the GPU nodes, FSx filesystem, cluster, and the image-build infra (ECR repo, S3
build-context bucket, CodeBuild project, IAM role). Each `*-clean` asks for confirmation first.
Re-running `make g6e-image` (or `make p5en-efa-image`) rebuilds the image in a few minutes.

## Quickstart (g6e path)

```bash
# Prereqs: export your AWS context (both optional; region defaults to us-west-2).
export AWS_REGION=us-west-2          # optional — where to deploy
export AWS_PROFILE=<your-profile>    # optional — omit to use default credentials

# --- Quickstart: stand up, run the self-heal demo, tear down ---
make g6e-up            # all infra: cluster + GPU nodepool + FSx + image  (~35 min)
make g6e-demo          # train -> inject XID -> hands-off repair -> resume from checkpoint
make g6e-clean         # destroy everything (asks to confirm)

# --- Or run the infra layers individually (same as g6e-up, step by step) ---
make g6e-cluster       # EKS Auto Mode cluster                            (~15 min)
make g6e-nodepool      # GPU NodePool + a g6e node                        (~3-5 min)
make g6e-storage       # FSx for Lustre + CSI + PVC                       (~10-13 min)
make g6e-image         # build + push the training image (CodeBuild)
make g6e-precheck      # verify the stack is ready to train

# --- Or drive the workload steps by hand (instead of g6e-demo) ---
make g6e-train         # launch the distributed LoRA fine-tune (JobSet)
make g6e-inject-fault  # inject a GPU fault (XID 79) on the rank-0 node
make g6e-diagnose      # pull a node log bundle, no SSH (kubectl ekslogs)

# Watch the chain in another terminal:
#   kubectl get nodes,nodeclaims -w
#   kubectl get jobset -o wide -w
```

Run `make help` to see every target for both paths.

## Fault injection

- **`make g6e-inject-fault`** runs `dcgmi test --inject` of a well-known XID, which the node
  monitoring agent detects through its real DCGM path and flips the `AcceleratedHardwareReady`
  condition. The p5en/EFA path has the equivalent `make p5en-efa-inject-fault`.

## Diagnostics without SSH

`make g6e-diagnose` (or `make p5en-efa-diagnose`) collects a full node log bundle using the
EKS-native **`NodeDiagnostic`** API via the
[`kubectl ekslogs`](https://github.com/aws/eks-node-monitoring-agent/tree/main/tools/kubectl-ekslogs)
plugin (installed on demand). The node monitoring agent gathers kernel `dmesg`, containerd,
kubelet, networking, IPAMD, and its own detection log into a tarball and streams it out through the
Kubernetes node proxy API — **no SSH, no SSM, no security-group changes**, and it works on Auto
Mode managed instances you cannot log into. This is the "diagnose" third of the EKS Auto Mode
**detect → repair → diagnose** story.

```bash
make g6e-diagnose                   # rank-0 (or first GPU) node -> ./node-logs/<node>-logs.tar.gz
NODE=i-0abc123 make g6e-diagnose    # a specific node
```

The agent's own detections land in `automode/eks-node-monitoring-agent.txt` inside the bundle. For
logs persisted to S3 instead of streamed locally, use `kubectl ekslogs --s3 <bucket> <node>`.

## Preflight

`make g6e-precheck` validates that a provisioned stack is ready to train: AWS credentials,
cluster reachability, the GPU NodePool (step 2), the FSx PVC is `Bound` (step 3), the training
image reference (step 4), and the JobSet CRD. Run it **after `make g6e-image` and before
`make g6e-train`**, or any time before re-running training on an existing cluster. (On a
first-ever run the JobSet CRD check warns until `make g6e-train` has installed it once.)

## Quickstart (p5en/EFA path — multi-node H200 FSDP)

The large-scale path fine-tunes Qwen2.5-32B-Instruct with full-parameter FSDP across
2× p5en.48xlarge (8× H200 + 16 EFA each), checkpointing to FSx for Lustre with
`torch.distributed.checkpoint`, over a high-bandwidth EFA fabric.

```bash
# Prereqs: your AWS context + the capacity reservation to provision p5en from
# (p5en.48xlarge is capacity-constrained; supply an ODCR or Capacity Block for ML).
export AWS_REGION=<your-region>                # required
export AWS_PROFILE=<your-profile>              # optional — omit to use default credentials
export CR_ID=<your-capacity-reservation-id>    # required — e.g. cr-0123456789abcdef0
export EFA_AZ=<az-of-your-reservation>         # required — e.g. us-east-1a

# --- Quickstart: stand up, run the self-heal demo, tear down ---
make p5en-efa-up       # all infra: cluster + p5en nodepool + FSx + image
make p5en-efa-demo     # NCCL busbw -> FSDP -> inject XID -> hands-off repair -> resume
make p5en-efa-clean    # destroy everything (asks to confirm)

# --- Or run the infra layers individually (same as p5en-efa-up, step by step) ---
make p5en-efa-cluster  # EKS Auto Mode cluster                            (~15 min)
make p5en-efa-nodepool # 2x p5en from the reservation + EFA
make p5en-efa-storage  # FSx for Lustre (RWX)
make p5en-efa-image    # DLC-based FSDP training image (CodeBuild)
make p5en-efa-precheck # verify the stack is ready to train

# --- Or drive the workload steps by hand (instead of p5en-efa-demo) ---
make p5en-efa-nccl-test    # NCCL all-reduce over EFA (busbw proof)
make p5en-efa-train        # launch the FSDP fine-tune (JobSet)
make p5en-efa-inject-fault # inject a GPU fault (XID 79) on the rank-0 node
make p5en-efa-diagnose     # pull a node log bundle, no SSH (kubectl ekslogs)

# Watch the chain in another terminal:
#   kubectl get nodes,nodeclaims -w
#   kubectl get jobset -o wide -w
```

### Known issue: hugepages requests can block Karpenter node provisioning

Do **not** request `hugepages-2Mi` in pod specs for these EFA workloads. Karpenter models
`hugepages-2Mi` capacity as `0` for **every** instance type (a long-standing, still-open
limitation — see [aws/karpenter-provider-aws#3315](https://github.com/aws/karpenter-provider-aws/issues/3315)),
so a pod that *requests* hugepages matches no instance type and Karpenter reports
`no instance type has enough resources` — silently blocking node provisioning, including
node-auto-repair replacements. This is **not** specific to reserved capacity; it applies to
on-demand and spot as well.

The node still provides hugepages at the OS level and EFA/libfabric uses them at runtime
regardless, so removing the Kubernetes request has no performance impact (NCCL bandwidth is
unchanged). `vpc.amazonaws.com/efa` requests are fine and do not trigger this. If
you have a workload that genuinely needs hugepages *gated by the scheduler*, you must pin the
NodePool to specific instance types and account for the limitation above.

## Architecture

### Components

- **EKS Auto Mode cluster** — bundles Karpenter, the node monitoring agent (systemd in the node
  image, not a DaemonSet), and node auto repair (default-on, non-configurable).
- **GPU NodePool / NodeClass** — Karpenter CRDs targeting `g6e` (NVIDIA L40S, 48 GB), single GPU
  per node. On EKS Auto Mode the NodePool is `karpenter.sh/v1` and the NodeClass is
  `eks.amazonaws.com/v1`; GPU pods select nodes with `nodeSelector: karpenter.sh/nodepool: gpu`.
- **FSx for Lustre** — `ReadWriteMany` shared filesystem for the base model cache, dataset, and
  checkpoints. Survives node replacement. The FSx CSI controller is granted AWS API access via
  EKS Pod Identity (Auto Mode blocks IMDS for non-hostNetwork pods).
- **Training workload** — LoRA fine-tune of Qwen2.5-1.5B-Instruct via `torchrun`, orchestrated
  by a **JobSet** with gang-restart (`restartStrategy: Recreate`). A required pod anti-affinity
  (`topologyKey: kubernetes.io/hostname`) places exactly one rank per node, so a node failure
  loses exactly one rank.
- **Fault injection** — `dcgmi test --inject` of a well-known XID, which flips the node condition
  through the agent's real DCGM path.

### Detection vs. diagnosis

**Detection and diagnosis are separate concerns** (per the EKS service team): detection runs
continuously and writes NodeConditions to drive repair; diagnosis runs on demand (via the
`NodeDiagnostic` API — see [Diagnostics without SSH](#diagnostics-without-ssh)) and collects
detailed artifacts for humans. You can diagnose a node that auto-repair has flagged but not yet
terminated.

### Storage & checkpoint contract

The g6e trainer (HuggingFace Trainer + PEFT LoRA) writes a checkpoint to
`/fsx/checkpoints/checkpoint-<step>` every 50 steps. Each checkpoint holds the LoRA adapter
weights, optimizer + scheduler state, per-rank RNG state, and `trainer_state.json` (records
`global_step`). On start, the trainer selects the highest-step checkpoint that contains
`trainer_state.json` (skipping any partial/corrupt dir) and resumes from it. The p5en/EFA path
uses `torch.distributed.checkpoint` (DCP) sharded checkpoints and resumes from the latest complete
checkpoint (`.metadata` present). This is what makes node replacement non-destructive to progress.

### p5en/EFA path (multi-node H200 FSDP over EFA)

The large-scale path demonstrates the same self-healing chain at multi-node scale:

- **Workload:** full-parameter FSDP fine-tune of Qwen2.5-32B-Instruct across 2× p5en.48xlarge
  (16 ranks, 8× H200 per node), one rank per node via pod anti-affinity so a node loss drops
  exactly one rank.
- **Interconnect:** EFA (16 interfaces/node) for high-bandwidth NCCL collectives.
- **Checkpoints:** `torch.distributed.checkpoint` (DCP) sharded checkpoints to FSx for Lustre
  (RWX), every `--save-steps`. Resume loads the latest complete checkpoint (`.metadata` present).
- **Repair chain:** dcgmi XID-79 injection → node monitoring agent sets
  `AcceleratedHardwareReady=False` within seconds → ~10-min toleration → node auto repair
  terminates and replaces the faulted node → JobSet gang-restart (`restartStrategy: Recreate`)
  → training resumes from the latest DCP checkpoint.

See the [hugepages known issue](#known-issue-hugepages-requests-can-block-karpenter-node-provisioning)
above for a Karpenter provisioning caveat that applies to EFA workloads on any capacity type.

## Repository layout

```
Makefile                         entry point — `make help` lists every target for both paths
terraform/g6e/cluster            EKS Auto Mode cluster + VPC (g6e)
terraform/g6e/storage            FSx security group + subnet lookups (g6e)
terraform/g6e/image              ECR repo + S3 build-context bucket + CodeBuild project + IAM (g6e)
terraform/p5en-efa/…             the same three layers for the p5en/EFA path
kubernetes/g6e/nodepool          GPU NodePool + NodeClass (g6e)
kubernetes/g6e/fsx               StorageClass + RWX PVC (g6e)
kubernetes/g6e/train             JobSet (headless service auto-created by the JobSet controller)
kubernetes/g6e/fault-injection   dcgmi --inject Job
kubernetes/p5en-efa/…            nodepool (EFA NodeClass), fsx, train (FSDP), nccl-benchmark
src/g6e                          train.py, checkpoint.py, buildspec.yml, Dockerfile, tests (g6e)
src/p5en-efa                     train_fsdp.py, checkpoint_dcp.py, nccl_allreduce.py, Dockerfile (p5en/EFA)
scripts/g6e                      g6e orchestration (wrapped by the Makefile), incl. diagnose.sh
scripts/p5en-efa                 p5en/EFA orchestration, incl. diagnose.sh
```

## Notes

- **EKS Auto Mode specifics:** the GPU NodePool is a Karpenter CRD (`karpenter.sh/v1`); the
  NodeClass is `eks.amazonaws.com/v1`. GPU pods must use
  `nodeSelector: karpenter.sh/nodepool: <name>`.
- **FSx on Auto Mode:** the FSx CSI controller is granted AWS access via EKS Pod Identity
  (`make g6e-storage` / `make p5en-efa-storage` sets this up), because Auto Mode blocks IMDS for
  non-hostNetwork pods.
- **Image builds** run in AWS CodeBuild (native linux/amd64), so no local Docker daemon is
  required and Apple Silicon users avoid slow emulated cross-builds.

## License

MIT-0. See `LICENSE`.

### Third-party model and dataset attribution

This sample downloads the following third-party artifacts at runtime (they are **not**
redistributed as part of this repository):

- **Models:** `Qwen/Qwen2.5-1.5B-Instruct` (g6e) and `Qwen/Qwen2.5-32B-Instruct` (p5en-efa),
  both licensed **Apache-2.0** by Alibaba Cloud.
- **Dataset:** [`nvidia/HelpSteer2`](https://huggingface.co/datasets/nvidia/HelpSteer2) by NVIDIA,
  licensed **CC-BY-4.0**. Fine-tuning uses this instruction/response dataset purely to give the
  self-healing workload a realistic task; the resulting fine-tune quality is not the point of the
  sample.
