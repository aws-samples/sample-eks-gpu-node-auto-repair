data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # Standard EKS (NOT Auto Mode): no Auto Mode compute block. GPU capacity is an explicit
  # managed node group so node auto repair can be tuned with nodeRepairConfigOverrides.
  eks_managed_node_groups = {
    # Small untainted node group for cluster system pods (coredns, metrics, etc.). The GPU node
    # group below is tainted nvidia.com/gpu=NoSchedule, so without this, coredns cannot schedule
    # and the cluster never becomes fully functional. EKS Auto Mode provides a general-purpose
    # pool for this automatically; a standard-EKS MNG cluster must supply one explicitly.
    system = {
      instance_types = ["m7i.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 2
      max_size       = 2
      desired_size   = 2
      labels         = { nodegroup = "system" }
    }

    gpu = {
      instance_types = var.gpu_instance_types
      ami_type       = "AL2023_x86_64_NVIDIA"
      min_size       = var.gpu_desired_size
      max_size       = var.gpu_desired_size + 1
      desired_size   = var.gpu_desired_size

      labels = { nodegroup = "gpu" }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # Node auto repair with per-XID overrides. The monitoring condition and repair action
      # use the EKS API enums (not the eksctl aliases) — confirm live (plan Task 14).
      node_repair_config = {
        enabled = true
        node_repair_config_overrides = [
          {
            node_monitoring_condition = "AcceleratedHardwareReady"
            node_unhealthy_reason     = "NvidiaXID79Error"
            min_repair_wait_time_mins = 10
            repair_action             = "Replace"
          },
          {
            node_monitoring_condition = "AcceleratedHardwareReady"
            node_unhealthy_reason     = "NvidiaXID64Error"
            min_repair_wait_time_mins = 30
            repair_action             = "Replace"
          },
          {
            node_monitoring_condition = "AcceleratedHardwareReady"
            node_unhealthy_reason     = "NvidiaXID63Error"
            min_repair_wait_time_mins = 10
            repair_action             = "NoAction"
          },
        ]
      }
    }
  }

  # EKS add-ons that Auto Mode otherwise bundles. The node monitoring agent add-on provides
  # the NMA DaemonSet + NodeDiagnostic CRD; Pod Identity agent is required for FSx CSI
  # (storage layer creates the association).
  addons = {
    # vpc-cni, kube-proxy and pod-identity MUST install BEFORE the node group: nodes stay
    # NotReady until the CNI is up, but the node group create waits for nodes to be Ready — a
    # deadlock if these install after compute. before_compute=true breaks it.
    vpc-cni                = { before_compute = true }
    kube-proxy             = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    # coredns needs schedulable nodes; the node monitoring agent runs on the nodes — both after.
    coredns = {}
    eks-node-monitoring-agent = {
      # The agent's bundled dcgm-server DaemonSet (which runs the nv-hostengine the agent reads
      # for GPU health) has no toleration for the GPU node taint by default, so on a cluster whose
      # ONLY GPU nodes are tainted it never schedules — the agent then reports
      # AcceleratedHardwareReady=False with reason DCGMError and GPU health monitoring is silently
      # broken. Tolerate the GPU taint so dcgm-server runs on the GPU nodes.
      configuration_values = jsonencode({
        dcgmAgent = {
          tolerations = [{
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          }]
        }
      })
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = var.tags
}
