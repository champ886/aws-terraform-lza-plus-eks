# RUNBOOK — Issues Encountered & Architecture Notes

This document captures the detailed architecture decisions made in this repo and every significant issue encountered during the build. It exists so the next person (or future you) doesn't repeat the same debugging sessions.

---

## High Level Architecture

### 1. Worker Nodes → EKS Control Plane (Private Connectivity)

**Module:** `modules/vpc-endpoints/`

Worker nodes communicate with the EKS control plane and AWS APIs entirely via **VPC Interface Endpoints** (AWS PrivateLink). There is no NAT Gateway and no internet route on the node subnets.

| Endpoint | Service | Purpose |
|---|---|---|
| `com.amazonaws.ap-southeast-2.eks` | EKS | Nodes communicate with control plane API privately |
| `com.amazonaws.ap-southeast-2.ec2` | EC2 | Node registration with the cluster |
| `com.amazonaws.ap-southeast-2.sts` | STS | IRSA token exchange for pod IAM roles |
| `com.amazonaws.ap-southeast-2.ecr.api` | ECR | ECR authentication |
| `com.amazonaws.ap-southeast-2.ecr.dkr` | ECR | Container image pulls |
| `com.amazonaws.ap-southeast-2.s3` *(Gateway)* | S3 | ECR image layer pulls — Gateway type, no hourly charge |
| `com.amazonaws.ap-southeast-2.autoscaling` | Autoscaling | Cluster Autoscaler scale-in/out operations |

All traffic stays within the AWS private network via PrivateLink. No internet routing required.

---

### 2. ECR Pull Through Cache

**Module:** `modules/ecr-pull-through/`

Rather than pulling images directly from public registries (which would require internet access and a NAT Gateway), nodes pull from **private ECR repositories** that act as a pull-through cache. ECR fetches from upstream on the first pull and caches the image indefinitely.

| ECR Prefix | Upstream Source | Used By |
|---|---|---|
| `registry-k8s-io` | registry.k8s.io | cluster-autoscaler |
| `ecr-public` | public.ecr.aws | ALB controller, Kubecost cost-model, Kubecost frontend |
| `docker-hub` | hub.docker.com | Grafana, Prometheus, node-exporter, kiwigrid sidecar |
| `quay` | quay.io | prometheus-config-reloader |

Nodes never touch the internet. ECR handles upstream fetching automatically.

---

## Issues Encountered

### ECR & Images

**`gcr.io` is not supported by ECR Pull Through Cache**
ECR pull-through supports a fixed list of upstream registries. `gcr.io` is not on it. Kubecost's default Helm chart points its cost-model and frontend images at `gcr.io/kubecost1/` — these had to be explicitly overridden to use `public.ecr.aws/kubecost` instead.

**Node IAM role was missing pull-through cache permissions**
ECR pull-through cache requires the node IAM role to have `ecr:CreateRepository` and `ecr:BatchImportUpstreamImage`. Without these, the first pull of any image fails silently — the pod enters `ImagePullBackOff` with no obvious reason why.

Required addition to the node instance profile:
```json
{
  "Effect": "Allow",
  "Action": [
    "ecr:CreateRepository",
    "ecr:BatchImportUpstreamImage"
  ],
  "Resource": "*"
}
```

**Kubecost Helm value names were wrong**
The Helm values `cost-analyzer.image.repository` and `frontend.image.repository` do not exist in the Kubecost chart. The correct keys are:
- `kubecostModel.image` — for the cost-model container
- `kubecostFrontend.image` — for the frontend container

**Grafana sidecar container needed an ECR override**
The `kube-prometheus-stack` chart injects a `kiwigrid/k8s-sidecar` container into the Grafana pod automatically. This is easy to miss. The sidecar image also needs to be overridden to pull from ECR, otherwise it will fail with `ImagePullBackOff` even after the main Grafana image is correctly redirected.

---

### Terraform State

**DynamoDB lock table only existed in the management account**
The `tf-locks` DynamoDB table was only created in the management account. Child accounts couldn't acquire a state lock when running Terraform in their own context. Either a table per account or cross-account DynamoDB access is required.

**Cross-account state access required a dedicated role**
A `TerraformStateRole` was created in the management account with permissions to read/write the S3 state bucket. Child account Terraform runs assume this role via the backend `assume_role` block.

**`role_arn` is not a valid top-level S3 backend key**
In some Terraform versions, setting `role_arn` directly in the `backend "s3"` block is not supported. The correct approach is the nested `assume_role` block:

```hcl
# Wrong
backend "s3" {
  role_arn = "arn:aws:iam::..."
}

# Correct
backend "s3" {
  assume_role = {
    role_arn = "arn:aws:iam::..."
  }
}
```

**Double role assumption causes 403**
`providers.tf` already assumes the correct deployment role for all AWS API calls. Running `assume-dev` beforehand and then running `terraform apply` causes the role to be assumed twice, which results in 403 permission errors. Run Terraform directly without pre-assuming a role.

---

### Kubernetes & Helm

**ALB controller had a wrong `depends_on`**
The ALB controller Terraform resource had `depends_on = [module.eks_addons]`. This meant that targeting ALB controller with `-target` would trigger the entire `eks_addons` module, causing Kubecost to deploy unexpectedly. The dependency was incorrect and was removed.

**`vpc-cni` must be running before any other pods**
The `vpc-cni` addon is responsible for assigning VPC IP addresses to pods. If any other pods are scheduled before `vpc-cni` is fully running, they will fail with `FailedCreatePodSandBox`. Always deploy and verify `vpc-cni` before proceeding with other workloads.

**EBS CSI driver was missing**
Kubecost and Prometheus use PersistentVolumeClaims. Without the `aws-ebs-csi-driver` addon, PVCs remain in `Pending` state and pods never start. The driver also requires an IRSA role with permissions to manage EBS volumes.

**StorageClass not set on Kubecost PVCs**
Even with the EBS CSI driver installed, Kubecost PVCs remained unbound because no StorageClass was specified and no default StorageClass was configured. Fixed by setting `storageClass: gp2` explicitly in the Kubecost Helm values.

**`eks-addons/main.tf` was corrupted by incremental edits**
After several rounds of manual edits to `eks-addons/main.tf`, Kubecost image override values accidentally ended up inside the cluster-autoscaler Helm release block. The cluster-autoscaler then failed to deploy because it received unknown Helm values. Always review a full diff of the file before applying after manual edits.

---

### General

**`assume-dev` session expires after 1 hour**
The `assume-dev` script generates temporary STS credentials that expire after 1 hour. Any `kubectl` or AWS CLI commands will start failing with auth errors after this. Re-run `assume-dev` to refresh credentials.

**`context deadline exceeded` on Helm was masking `ImagePullBackOff`**
When a Helm release times out, it surfaces as `context deadline exceeded`. This looks like a networking or Helm issue but is often caused by pods that are stuck in `ImagePullBackOff` — the release times out waiting for pods that will never become ready. Always check pod status with `kubectl get pods -A` and `kubectl describe pod <name>` before investigating Helm or network issues.

---

## Checklist for Fresh Deployments

- [ ] `TerraformStateRole` exists in management account
- [ ] S3 bucket policy allows access from child account role ARN
- [ ] DynamoDB `tf-locks` table accessible from target account
- [ ] Node IAM role includes `ecr:CreateRepository` and `ecr:BatchImportUpstreamImage`
- [ ] All upstream image references overridden to ECR pull-through prefixes
- [ ] Kubecost Helm values use `kubecostModel.image` and `kubecostFrontend.image`
- [ ] Grafana sidecar (`kiwigrid/k8s-sidecar`) image overridden to ECR
- [ ] `vpc-cni` addon running and healthy before scheduling other pods
- [ ] `aws-ebs-csi-driver` addon + IRSA role in place before deploying Prometheus/Kubecost
- [ ] StorageClass explicitly set in Kubecost Helm values
- [ ] Do not run `assume-dev` before `terraform apply`