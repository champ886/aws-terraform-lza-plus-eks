# aws-terraform-lza-plus-eks

> **A lean, cost-conscious pattern for running private EKS on AWS — no NAT Gateway, no unnecessary compute, no idle spend.**

This repo demonstrates how to build a production-grade EKS cluster on AWS Landing Zone Accelerator (LZA) using Terraform, optimised for cost and simplicity. Every architectural decision is driven by the question: *does this need to exist, and does it need to cost money?*

---

## The Core Idea

Most EKS tutorials assume a NAT Gateway, public subnets, and liberal internet access. That approach is fast to set up but expensive to run and harder to secure.

This repo takes the opposite approach:

- **No NAT Gateway** (~$35/month per AZ, saved)
- **No internet egress from nodes** — all AWS API traffic goes via VPC Interface Endpoints (PrivateLink)
- **No public image registries hit by nodes** — all container images pulled via ECR Pull Through Cache
- **No redundant tooling** — only the add-ons actually needed are deployed

The result is a fully private, air-gapped-style EKS cluster that costs significantly less to run and has a smaller attack surface.

---

## What This Repo Provisions

| Component | Module | Purpose |
|---|---|---|
| VPC Interface Endpoints | `modules/vpc-endpoints` | Private connectivity from nodes to AWS APIs (EKS, EC2, STS, ECR, S3, Autoscaling) — replaces NAT Gateway |
| ECR Pull Through Cache | `modules/ecr-pull-through` | Proxy and cache for upstream container registries (Docker Hub, quay.io, registry.k8s.io, public.ecr.aws) |
| EKS Cluster | `modules/eks` | Private EKS control plane + managed node groups |
| EKS Add-ons | `modules/eks-addons` | vpc-cni, aws-ebs-csi-driver, cluster-autoscaler, ALB controller, Kubecost, Prometheus, Grafana |
| IAM / IRSA | Inline per add-on | Least-privilege IAM roles bound to Kubernetes service accounts |
| Terraform State | S3 + DynamoDB | Cross-account state with role assumption — no credentials stored |

---

## Cost Philosophy

### What you're not paying for

| Removed Component | Typical Monthly Cost |
|---|---|
| NAT Gateway (per AZ) | ~$35 + data transfer |
| Public ECR data transfer (pulling from internet) | Variable, adds up at scale |
| Oversized node groups with no autoscaling | Significant at idle |

### What replaces it (cheaper)

| Replacement | Cost |
|---|---|
| VPC Interface Endpoints (6 endpoints) | ~$7/month per endpoint — fixed, predictable |
| S3 Gateway Endpoint | Free |
| ECR Pull Through Cache | Storage cost only after first pull — images cached indefinitely |
| Cluster Autoscaler | Free (runs on existing nodes) |

At moderate scale, this architecture is **cheaper than NAT Gateway** while being more secure and fully private.

---

## Architecture Summary

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

| Add-on | Why It's Here |
|---|---|
| `vpc-cni` | Required for pod networking in VPC-native mode |
| `aws-ebs-csi-driver` | Required for persistent volume support (Prometheus, Kubecost) |
| `cluster-autoscaler` | Scale nodes down when idle — core to keeping costs low |
| `aws-load-balancer-controller` | Provision ALBs from Kubernetes ingress objects |
| `kubecost` | Real-time cost visibility per namespace/workload |
| `kube-prometheus-stack` | Metrics and alerting (Prometheus + Grafana) |

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

> `providers.tf` handles role assumption for AWS resources. Do not run `assume-dev` before `terraform apply` — it will cause double-assumption and 403 errors.

---

## Deployment Order

Order matters. These components have hard dependencies on each other:

1. VPC + VPC Endpoints
2. EKS cluster
3. `vpc-cni` addon ← **nodes cannot schedule pods until this is running**
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
- DynamoDB table `tf-locks` with cross-account access configured
- `assume-dev` script for interactive CLI sessions (expires every 1 hour — re-run as needed)

---

## Further Reading

See [`RUNBOOK.md`](./RUNBOOK.md) for a full account of the issues encountered during build, including ECR pull-through quirks, Helm value corrections, Terraform state gotchas, and Kubernetes dependency ordering.

---

## License

MIT
