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

## Paths

This repo ships four symmetric, self-contained paths across two families. Pick based on the
hardware you want to show **and** the compute/repair model you want to demonstrate:

| Path | Instances | Workload | Networking | Compute & repair | Make prefix | Manifests / scripts |
|---|---|---|---|---|---|---|
| **g6e** (entry-level) | 1× GPU per node, `g6e` / NVIDIA L40S | LoRA fine-tune of Qwen2.5-1.5B, JobSet `Recreate` | standard VPC CNI | EKS **Auto Mode**; node auto repair always-on, non-configurable, always `Replace` | `make g6e-*` | `kubernetes/g6e`, `scripts/g6e`, `terraform/g6e`, `src/g6e` |
| **p5en-efa** (large-scale) | 2× `p5en.48xlarge` (8× H200 each) | full-parameter FSDP fine-tune, JobSet `Recreate` | EFA / NCCL (16 EFA NICs) | EKS **Auto Mode**; node auto repair always-on, non-configurable, always `Replace` | `make p5en-efa-*` | `kubernetes/p5en-efa`, `scripts/p5en-efa`, `terraform/p5en-efa`, `src/p5en-efa` |
| **mng-g6e** | 1× GPU per node, `g6e` / NVIDIA L40S | same LoRA fine-tune of Qwen2.5-1.5B, JobSet `Recreate` | standard VPC CNI | EKS **Managed Node Group**; configurable node auto repair via `nodeRepairConfigOverrides` | `make mng-g6e-*` | `kubernetes/mng-g6e`, `scripts/mng-g6e`, `terraform/mng-g6e` (image reused from `g6e`) |
| **mng-p5en-efa** | 2× `p5en.48xlarge` (8× H200 each) | full-parameter FSDP fine-tune, JobSet `Recreate` | EFA / NCCL (16 EFA NICs) | EKS **Managed Node Group**; configurable node auto repair via `nodeRepairConfigOverrides` | `make mng-p5en-efa-*` | `kubernetes/mng-p5en-efa`, `scripts/mng-p5en-efa`, `terraform/mng-p5en-efa` (image reused from `p5en-efa`) |

All four paths use the same self-healing primitives (node monitoring agent → node condition →
repair → JobSet gang-restart → checkpoint resume) and reuse the same training images, JobSet
manifests, FSx PVCs, and checkpoint logic — only the compute + repair layer differs. The two
families differ in **how** repair is governed:

- **g6e / p5en-efa** run on **EKS Auto Mode**: node auto repair is bundled, always-on, and
  **non-configurable** — every `AcceleratedHardwareReady` fault results in a `Replace`, with
  nothing to install.
- **mng-g6e / mng-p5en-efa** run on **EKS Managed Node Groups** with the node monitoring agent
  installed as an **add-on**, and demonstrate **configurable** per-fault repair via
  `nodeRepairConfigOverrides` — tuning `repairAction` (`Replace` / `Reboot` / `NoAction`) and
  `minRepairWaitTimeMins` per `nodeUnhealthyReason`. See
  [Configurable node repair (MNG paths)](#configurable-node-repair-mng-paths).

Within each family, the **g6e** path is the quickest, cheapest way to see the full chain; the
**p5en-efa** path additionally proves EFA bandwidth and multi-node FSDP at scale.

> Validated end-to-end on **Amazon EKS Auto Mode, Kubernetes 1.36**:
> - **g6e** (`g6e.4xlarge` / L40S): fault injection → agent detection → node auto
>   repair → JobSet gang-restart → checkpoint resume.
> - **p5en-efa** (`p5en.48xlarge` / H200, platform `eks.9`): high-bandwidth NCCL
>   all-reduce over EFA, 16-rank FSDP, DCP checkpointing, XID detection, and the full hands-off repair + resume.
>
> See [How it works](#how-it-works) for the chain of events and timings.

The quickstart below uses the **g6e** path; substitute the `p5en-efa-` prefix for the
large-scale path, or the `mng-g6e-` / `mng-p5en-efa-` prefixes for the Managed Node Group paths
([MNG quickstarts](#quickstart-mng-paths)).

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

Run `make help` to see every target for all paths.

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

(This caveat is Auto-Mode/Karpenter-specific. The MNG paths provision through an EC2 Auto Scaling
group + launch template, not Karpenter, so it does not apply to `mng-g6e` / `mng-p5en-efa`.)

## Quickstart (MNG paths)

The two **Managed Node Group** paths stand up a standard EKS cluster (not Auto Mode), install the
node monitoring agent as an add-on, and enable configurable node auto repair with the
[override matrix](#the-override-matrix). They reuse the training images built by their Auto Mode
siblings (`g6e` / `p5en-efa`), so there is no separate image build to own — see
[Shared-image teardown](#shared-image-teardown).

### mng-g6e (single-GPU L40S, Managed Node Group)

```bash
# Prereqs: export your AWS context (both optional; region defaults to us-west-2).
export AWS_REGION=us-west-2          # optional — where to deploy
export AWS_PROFILE=<your-profile>    # optional — omit to use default credentials

# --- Quickstart: stand up, run the self-heal demo, tear down ---
make mng-g6e-up        # all infra: cluster + GPU MNG (repair overrides) + storage + image
make mng-g6e-demo      # train -> inject XID 79 (Replace) + documented follow-on injects
make mng-g6e-clean     # destroy the MNG cluster + storage (NOT the shared image; asks to confirm)

# --- Or run the infra layers individually (same as mng-g6e-up, step by step) ---
make mng-g6e-cluster   # standard EKS cluster + GPU MNG with nodeRepairConfig overrides
make mng-g6e-nodegroup # wait for GPU MNG nodes + verify NMA add-on and device plugin
make mng-g6e-storage   # FSx + CSI + Pod Identity + StorageClass/PVC
make mng-g6e-image     # ensure the training image exists (reuses the g6e image build)
make mng-g6e-precheck  # verify the stack is ready to train

# --- Or drive the workload steps by hand (instead of mng-g6e-demo) ---
make mng-g6e-train         # launch the LoRA fine-tune (JobSet)
make mng-g6e-inject-fault  # inject a GPU fault (XID=79 default; set XID=63|64|95 to vary)
make mng-g6e-diagnose      # pull a node log bundle, no SSH (kubectl ekslogs)
```

### mng-p5en-efa (multi-node H200 FSDP over EFA, Managed Node Group)

Like the Auto Mode `p5en-efa` path, this provisions p5en.48xlarge from a capacity reservation, so
it needs the same `CR_ID` + `EFA_AZ` environment.

```bash
# Prereqs: your AWS context + the capacity reservation to provision p5en from.
export AWS_REGION=<your-region>                # required
export AWS_PROFILE=<your-profile>              # optional — omit to use default credentials
export CR_ID=<your-capacity-reservation-id>    # required — e.g. cr-0123456789abcdef0
export EFA_AZ=<az-of-your-reservation>         # required — e.g. us-east-1a

# --- Quickstart: stand up, run the self-heal demo, tear down ---
make mng-p5en-efa-up       # all infra: cluster + EFA GPU MNG (repair overrides) + storage + image
make mng-p5en-efa-demo     # NCCL -> FSDP -> inject XID 79 (Replace) + documented follow-on injects
make mng-p5en-efa-clean    # destroy the MNG cluster + storage (NOT the shared image; asks to confirm)

# --- Or run the infra layers individually (same as mng-p5en-efa-up, step by step) ---
make mng-p5en-efa-cluster   # standard EKS cluster + EFA GPU MNG with nodeRepairConfig overrides
make mng-p5en-efa-nodegroup # wait for the 2 EFA GPU MNG nodes + verify NMA add-on + device plugins
make mng-p5en-efa-storage   # FSx for Lustre + CSI + Pod Identity + StorageClass/PVC
make mng-p5en-efa-image     # ensure the DLC training image exists (reuses the p5en-efa image build)
make mng-p5en-efa-precheck  # verify the stack is ready to train

# --- Or drive the workload steps by hand (instead of mng-p5en-efa-demo) ---
make mng-p5en-efa-nccl-test    # NCCL all-reduce over EFA (busbw proof)
make mng-p5en-efa-train        # launch the FSDP fine-tune (JobSet)
make mng-p5en-efa-inject-fault # inject a GPU fault (XID=79 default; set XID=63|64|95 to vary)
make mng-p5en-efa-diagnose     # pull a node log bundle, no SSH (kubectl ekslogs)
```

### Shared-image teardown

Each MNG path **reuses the training image built by its Auto Mode sibling** — `mng-g6e` consumes
the image the `g6e` path builds, and `mng-p5en-efa` consumes the `p5en-efa` image (the container
is identical regardless of the node-provisioning model). The image layer therefore has a single
owner:

- `make mng-g6e-clean` / `make mng-p5en-efa-clean` destroy the MNG cluster + storage **but NOT the
  shared training image** (that layer — the ECR repo, S3 build-context bucket, CodeBuild project,
  and IAM — is owned by the `g6e` / `p5en-efa` paths).
- `make g6e-clean` / `make p5en-efa-clean` remove the shared image layer. If you tear down both an
  Auto Mode path and its MNG sibling, run the MNG `*-clean` first and the owning path's `*-clean`
  last.

`make help` lists every target for all four paths and is the source of truth.

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

> **Node monitoring agent currency:** The EKS node monitoring agent is at **v1.7.2** (Sep 2026),
> which adds NVIDIA/DCGM monitoring on **arm64 GPU nodes** (e.g. Grace-based GPU instances), block
> device I/O error detection, and an external DCGM hostengine option. On EKS Auto Mode the agent is
> part of the managed node image and is kept current for you; no action is required.

### Detection vs. diagnosis

**Detection and diagnosis are separate concerns** (per the EKS service team): detection runs
continuously and writes NodeConditions to drive repair; diagnosis runs on demand (via the
`NodeDiagnostic` API — see [Diagnostics without SSH](#diagnostics-without-ssh)) and collects
detailed artifacts for humans. You can diagnose a node that auto-repair has flagged but not yet
terminated.

> **Detection is broader than NMA node conditions.** As of June 2026, EKS Auto Mode's compute
> controller also polls EC2 `DescribeInstanceStatus` and automatically replaces nodes on scheduled
> maintenance events and instance/system status-check failures — detection that does not depend on
> the node monitoring agent. The GPU-fault path this sample injects (`dcgmi --inject` → NMA →
> `AcceleratedHardwareReady=False`) is one detection source among several the data plane watches.

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

## Configurable node repair (MNG paths)

The Auto Mode paths (`g6e`, `p5en-efa`) show node auto repair at its simplest: there is nothing
to install, repair is always-on and **non-configurable**, and every `AcceleratedHardwareReady`
fault results in a `Replace`. The Managed Node Group paths (`mng-g6e`, `mng-p5en-efa`) show the
other end of the spectrum — repair you opt into and tune per fault.

### Auto Mode vs. MNG

| | **Auto Mode** (`g6e` / `p5en-efa`) | **Managed Node Group** (`mng-g6e` / `mng-p5en-efa`) |
|---|---|---|
| Node monitoring agent | systemd service baked into the AMI (nothing to install) | installed as an **add-on** (DaemonSet) |
| Node auto repair | always-on, bundled | opt in via `nodeRepairConfig.enabled = true` on the MNG |
| Configurability | none | tune `repairAction` + `minRepairWaitTimeMins` per `nodeUnhealthyReason` via `nodeRepairConfigOverrides` |
| Repair actions | `Replace` only | `Replace`, `Reboot`, `NoAction` |

On MNG you enable `nodeRepairConfig` on the node group and attach a list of
`nodeRepairConfigOverrides`, each keyed by a `nodeUnhealthyReason`, that override the built-in
default `repairAction` and `minRepairWaitTimeMins` for that reason.

### The override matrix

The MNG default for `AcceleratedHardwareReady` faults is **`Reboot` after 10 minutes**. This
sample ships three deliberate overrides plus one un-overridden reason (so the default `Reboot`
remains visible side by side):

| Injected XID | Reason code | MNG default | Override | Why |
|---|---|---|---|---|
| 79 (fell off bus) | NvidiaXID79Error | Reboot @10m | **Replace @10m** | Bus-level loss; a reboot cannot recover it — only a bare-metal replacement can, so replace at the earliest the API allows. |
| 48 / 64 (double-bit ECC / remap failure) | NvidiaXID64Error | Reboot @10m | **Replace @30m** | Degrading silicon; wait longer before the destructive replace in case the fault is transient. Documented tradeoff (see below). |
| 63 (memory remapping event) | NvidiaXID63Error | Reboot @10m | **NoAction** | Informational wear event; ride it out instead of churning the node. |
| 95 (uncontained memory error) | NvidiaXID95Error | Reboot @10m | *(not overridden)* | Left at the default so the demo shows a real `Reboot` (same instance ID). |

> **`minRepairWaitTimeMins` constraint:** the EKS API requires each override's
> `minRepairWaitTimeMins` to be **between 10 and 120 and a multiple of 10** — values like `5` are
> rejected at `CreateNodegroup` with `InvalidParameterException`. That is why the fastest override
> here is `@10m`, not a shorter interval.

### The 48/64 tradeoff — documented honestly

Overriding 48/64 to `Replace` is a judgment call, **not** a universal truth — `Reboot` is the
right answer for many fleets:

- **Reboot wins** when you want the fastest recovery and want to keep the instance (a warm local
  NVMe scratch disk, the same reserved ODCR slot, the same IP) and the fault may be a transient GPU
  wedge that a reset clears.
- **Replace wins** for long, checkpointed distributed training: a gang-restart already discards the
  rank and resumes from a checkpoint, so reboot's instance-preservation advantage is moot, while
  degrading silicon is likely to re-fail mid-run — fresh hardware is cheap insurance **when you
  have spare known-good capacity**.
- **Caveat:** on a tightly-sized ODCR, `Replace` needs the terminated node's reservation slot to
  free before a replacement can launch; `Reboot` keeps the slot. The right choice is
  capacity-posture dependent.

### Detect → repair → diagnose still holds

On MNG the node monitoring agent runs as an **add-on DaemonSet** (versus the Auto Mode systemd
agent baked into the AMI), relying on the add-on's default tolerations to stay scheduled on the
GPU node group. The detection source is the same (`dcgmi --inject` → NMA →
`AcceleratedHardwareReady=False` / `NvidiaXID<N>Error`), and the **diagnose** third of the story
is unchanged: `make mng-g6e-diagnose` / `make mng-p5en-efa-diagnose` pull a full node log bundle
via the `NodeDiagnostic` API (`kubectl ekslogs`) — the add-on ships the CRD controller, so this
works even though MNG nodes also allow SSH/SSM.

For the `Reboot` and `NoAction` behaviors specifically: a `Reboot` keeps the same instance ID (the
node goes NotReady, reboots, rejoins, and the gang-restart re-lands the rank on the same
instance); a `NoAction` flips the condition to `False` but fires no repair and leaves the node
`Ready`.

### GPU health monitoring requires the dcgm-server toleration

The node monitoring agent reads GPU health from an `nv-hostengine` provided by the add-on's bundled
`dcgm-server` DaemonSet. That DaemonSet does **not** tolerate custom taints by default, so on these
paths — whose only GPU nodes carry `nvidia.com/gpu=NoSchedule` — it would never schedule, and the
agent would report `AcceleratedHardwareReady=False` with reason `DCGMError` instead of real GPU
health. Both cluster layers therefore pass a toleration to the agent add-on via
`configuration_values` (`dcgmAgent.tolerations`); without it, GPU fault detection silently does not
work. This is specific to tainted-GPU-only MNG clusters; EKS Auto Mode handles it internally.

### Observed live run (EKS 1.37, g6e MNG)

All four behaviors validated end-to-end on a live `mng-g6e` cluster (Kubernetes 1.37, node
monitoring agent v1.7.2). Each fault was injected with `dcgmi test --inject -f 230 -v <XID>` against
the `dcgm-server` host engine the agent reads:

| Injected XID | Condition reason | Override | Observed result |
|---|---|---|---|
| 63 | `NvidiaXID63Error` | NoAction | Node stayed `Ready`, **same instance**, no repair |
| 79 | `NvidiaXID79Error` | Replace @10m | Node cordoned → drained → instance **terminated and replaced** (new instance) |
| 95 | `NvidiaXID95Error` | *(default)* Reboot | Node rebooted — **same instance** (new boot ID), condition recovered |
| 64 | `NvidiaXID64Error` | Replace @30m | After the 30-min wait, instance **terminated and replaced** |

> **Reproducing the injection:** keep the injected field resident (re-inject periodically) through
> the repair wait — a single injection decays and the condition reason oscillates between
> `NvidiaXID<N>Error` and a generic `DCGMHealthCode<N>`, which can prevent the override from
> matching. Inject against the node's `dcgm-server` pod (the hostengine the agent actually reads).

## Repository layout

```
Makefile                         entry point — `make help` lists every target for all paths
terraform/g6e/cluster            EKS Auto Mode cluster + VPC (g6e)
terraform/g6e/storage            FSx security group + subnet lookups (g6e)
terraform/g6e/image              ECR repo + S3 build-context bucket + CodeBuild project + IAM (g6e)
terraform/p5en-efa/…             the same three layers for the p5en/EFA path
kubernetes/g6e/nodepool          GPU NodePool + NodeClass (g6e)
kubernetes/g6e/fsx               StorageClass + RWX PVC (g6e)
kubernetes/g6e/train             JobSet (headless service auto-created by the JobSet controller)
kubernetes/g6e/fault-injection   dcgmi --inject Job
kubernetes/p5en-efa/…            nodepool (EFA NodeClass), fsx, train (FSDP), nccl-benchmark
terraform/mng-g6e/cluster        standard EKS cluster + VPC + GPU MNG (nodeRepairConfig overrides) + add-ons
terraform/mng-g6e/storage        FSx security group + subnet lookups (mng-g6e; image reused from g6e)
terraform/mng-p5en-efa/…         the same cluster + storage layers for the EFA MNG path (image reused from p5en-efa)
kubernetes/mng-g6e/…             fsx, train (MNG label selector), fault-injection (XID-parameterized)
kubernetes/mng-p5en-efa/…        fsx, train (FSDP), nccl-benchmark, fault-injection (XID-parameterized)
src/g6e                          train.py, checkpoint.py, buildspec.yml, Dockerfile, tests (g6e)
src/p5en-efa                     train_fsdp.py, checkpoint_dcp.py, nccl_allreduce.py, Dockerfile (p5en/EFA)
scripts/g6e                      g6e orchestration (wrapped by the Makefile), incl. diagnose.sh
scripts/p5en-efa                 p5en/EFA orchestration, incl. diagnose.sh
scripts/mng-g6e                  mng-g6e orchestration (incl. XID-parameterized inject-fault.sh, diagnose.sh)
scripts/mng-p5en-efa             mng-p5en-efa orchestration (incl. inject-fault.sh, nccl-test, diagnose.sh)
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
