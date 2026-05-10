# aws-terraform-lza-plus-eks

> **A production-ready, cost-optimised EKS pattern for AWS Landing Zone — no NAT Gateway, no unnecessary compute, no idle spend.**

This repo is a working reference architecture for teams running private EKS on AWS in a real production environment. It is not a tutorial. Every component exists because it was needed, and every cost was interrogated before it was accepted.

---

## Who This Is For

Teams that are:

- Running EKS in a regulated or security-conscious environment and need fully private node networking
- Paying NAT Gateway bills and wondering if there's a better way
- Trying to get cost visibility and autoscaling working in a production cluster without adding complexity for its own sake
- Deploying across multiple AWS accounts (dev + prod) with proper state isolation

If you're building a demo or a learning environment, this is probably more than you need. If you're running workloads that matter, read on.

---

## The Core Idea

Most EKS setups assume a NAT Gateway, public subnets, and open internet access from nodes. That approach works, but it has a cost: roughly **$35–70/month per AZ just for the gateway**, plus data transfer, plus the attack surface of nodes that can initiate outbound internet connections.

This repo replaces NAT Gateway entirely with two cheaper, more secure alternatives:

- **VPC Interface Endpoints (PrivateLink)** — nodes talk to AWS APIs over the private AWS network. No internet required.
- **ECR Pull Through Cache** — nodes pull container images from a private ECR registry that proxies and caches upstream registries. No DockerHub hits from production nodes.

The result is a fully private cluster where **no traffic leaves the AWS network** and **the monthly cost of the networking layer is fixed and predictable**, not variable based on data transfer.

---

## What This Repo Provisions

| Component | Module | Purpose |
|---|---|---|
| VPC Interface Endpoints | `modules/vpc-endpoints` | Private connectivity from nodes to AWS APIs — replaces NAT Gateway |
| ECR Pull Through Cache | `modules/ecr-pull-through` | Proxy and cache for upstream registries (Docker Hub, quay.io, registry.k8s.io, public.ecr.aws) |
| EKS Cluster | `modules/eks` | Private EKS control plane + managed node groups |
| EKS Add-ons | `modules/eks-addons` | vpc-cni, aws-ebs-csi-driver, cluster-autoscaler, ALB controller, Kubecost, Prometheus, Grafana |
| IAM / IRSA | Inline per add-on | Least-privilege IAM roles bound to Kubernetes service accounts |
| Terraform State | S3 + DynamoDB | Cross-account state with role assumption — no credentials in code |

---

## Cost Model

### What you're not paying for

| Removed Component | Typical Monthly Cost |
|---|---|
| NAT Gateway (per AZ) | ~$35 + data transfer |
| Public ECR / Docker Hub data transfer | Variable — adds up quickly at scale |
| Oversized, always-on node groups | Significant at idle without autoscaling |

### What replaces it

| Replacement | Cost |
|---|---|
| VPC Interface Endpoints (6 endpoints) | ~$7/month per endpoint — fixed, no data transfer surprises |
| S3 Gateway Endpoint | Free |
| ECR Pull Through Cache | Storage cost only after first pull — images cached indefinitely |
| Cluster Autoscaler | Free — runs on existing nodes, scales them down when idle |

At moderate scale, this architecture is **cheaper than a NAT Gateway setup** while being more secure. At higher scale, the savings compound.

The goal is not to spend zero — it is to spend predictably, and only on things that earn their keep.

---

## Architecture

```
Worker Nodes
│
├──▶ VPC Interface Endpoints (PrivateLink)
│       ├── eks          → EKS control plane API
│       ├── ec2          → Node registration
│       ├── sts          → IRSA token exchange
│       ├── ecr.api      → ECR authentication
│       ├── ecr.dkr      → Image pulls
│       ├── s3 (Gateway) → Image layer pulls (free)
│       └── autoscaling  → Cluster Autoscaler
│
└──▶ Private ECR (Pull Through Cache)
        ├── registry.k8s.io  → cluster-autoscaler images
        ├── public.ecr.aws   → ALB controller, Kubecost
        ├── hub.docker.com   → Grafana, Prometheus, exporters
        └── quay.io          → prometheus-config-reloader
```

No traffic leaves the AWS network. No internet gateway required on node subnets.

---

## Add-ons Deployed

Each add-on was included deliberately. None are here for completeness.

| Add-on | Why It's Here |
|---|---|
| `vpc-cni` | Required for pod networking in VPC-native mode — nothing works without it |
| `aws-ebs-csi-driver` | Required for persistent volumes — Prometheus and Kubecost need this |
| `cluster-autoscaler` | Scales nodes down when idle — central to keeping the monthly bill flat |
| `aws-load-balancer-controller` | Provisions ALBs from Kubernetes ingress objects — no manual LB management |
| `kubecost` | Real-time cost visibility per namespace and workload — holds the team accountable |
| `kube-prometheus-stack` | Metrics and alerting — Prometheus + Grafana, standard stack |

---

## Environments

This repo supports two environments: **dev** and **prod**. They share the same modules but differ on account ID, CIDR range, and cluster name.

| | Dev | Prod |
|---|---|---|
| Account ID | `<dev-account-id>` | `<prod-account-id>` |
| CIDR | `10.1.0.0/16` | `10.2.0.0/16` |
| Cluster name | `lean-dev` | `lean-prod` |

Prod is not a copy of dev with bigger nodes. It runs the same lean architecture — same endpoint pattern, same pull-through cache, same autoscaler. Scale is handled by the autoscaler, not by provisioning headroom.

---

## Terraform State

State is stored in S3 with DynamoDB locking, accessed via cross-account role assumption. No credentials are stored in code.

```hcl
terraform {
  backend "s3" {
    bucket         = "your-tf-state-bucket"
    key            = "path/to/state.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "tf-locks"

    assume_role = {
      role_arn = "arn:aws:iam::MANAGEMENT_ACCOUNT_ID:role/TerraformStateRole"
    }
  }
}
```

> `providers.tf` handles role assumption for AWS resources. Do not run `assume-dev` before `terraform apply` — double assumption causes 403 errors.

---

## Deployment Order

Order is not optional. These components have hard dependencies:

1. VPC + VPC Endpoints
2. EKS cluster
3. `vpc-cni` addon ← **pods cannot be scheduled until this is running**
4. `aws-ebs-csi-driver` + IRSA role ← **PVCs will not bind without this**
5. Remaining EKS add-ons
6. ALB Controller
7. Cluster Autoscaler
8. Kubecost / Prometheus / Grafana

---

## Prerequisites

- Terraform >= 1.3
- AWS CLI with credentials for the target account
- `TerraformStateRole` deployed in the management account
- DynamoDB table `tf-locks` accessible cross-account
- `assume-dev` script for interactive CLI sessions (1-hour expiry — re-run as needed)

---

## Further Reading

See [`RUNBOOK.md`](./RUNBOOK.md) for a full account of the issues encountered during build: ECR pull-through quirks, Helm value corrections, Terraform state cross-account gotchas, and Kubernetes dependency ordering. Most of the hard problems are already solved here.

---

## License

MIT