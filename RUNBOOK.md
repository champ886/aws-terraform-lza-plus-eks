# RUNBOOK — Issues Encountered & Architecture Notes

Hard-won notes from building this repo. Read before you touch anything.

---

## Architecture Quick Reference

### VPC Endpoints (replaces NAT Gateway)

Seven endpoints. All traffic stays on the AWS private network.

| Endpoint | Purpose |
|---|---|
| `eks` | Nodes → control plane API |
| `ec2` | Node registration |
| `sts` | IRSA token exchange |
| `ecr.api` | ECR authentication |
| `ecr.dkr` | Image pulls |
| `s3` *(Gateway, free)* | ECR image layer pulls |
| `autoscaling` | Cluster Autoscaler scale operations |

### ECR Pull Through Cache

Nodes never hit the internet. ECR fetches upstream on first pull and caches indefinitely.

| Prefix | Upstream | Used by |
|---|---|---|
| `registry-k8s-io` | registry.k8s.io | cluster-autoscaler |
| `ecr-public` | public.ecr.aws | ALB controller, Kubecost |
| `docker-hub` | hub.docker.com | Grafana, Prometheus, exporters |
| `quay` | quay.io | prometheus-config-reloader |

---

## Issues & Fixes

### ECR & Images

**`gcr.io` is not supported by ECR pull-through.** Kubecost's default chart pulls from `gcr.io/kubecost1/` — override to `public.ecr.aws/kubecost` in Helm values.

**Node IAM role needs two extra permissions.** Without these, first pulls fail silently with `ImagePullBackOff`:
```json
"Action": ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"]
```

**Kubecost Helm value names.** The values `cost-analyzer.image.repository` and `frontend.image.repository` don't exist. Use:
- `kubecostModel.image`
- `kubecostFrontend.image`

**Grafana injects a sidecar you'll forget.** `kube-prometheus-stack` adds `kiwigrid/k8s-sidecar` automatically. Override its image to ECR or it will `ImagePullBackOff` even after Grafana itself is fixed.

---

### Terraform State

**DynamoDB lock table must be cross-account accessible.** `tf-locks` was only in the management account. Child accounts need either their own table or cross-account DynamoDB access.

**`role_arn` is not a valid top-level S3 backend key.** Use the nested block:
```hcl
# Wrong
backend "s3" { role_arn = "arn:aws:iam::..." }

# Correct
backend "s3" {
  assume_role = { role_arn = "arn:aws:iam::..." }
}
```

**Don't run `assume-dev` before `terraform apply`.** `providers.tf` assumes the deployment role itself. Pre-assuming causes double assumption → 403.

---

### Kubernetes & Helm

**`vpc-cni` must be healthy before anything else.** It assigns VPC IPs to pods. Deploy it first, verify it's running, then proceed. Skipping this causes `FailedCreatePodSandBox` on every subsequent pod.

**EBS CSI driver is not optional.** Prometheus and Kubecost use PVCs. Without `aws-ebs-csi-driver` + its IRSA role, PVCs stay `Pending` forever.

**Set StorageClass explicitly in Kubecost Helm values.** No default StorageClass was configured, so PVCs stayed unbound even with the driver installed. Fix: `storageClass: gp2`.

**Wrong `depends_on` on ALB controller.** Had `depends_on = [module.eks_addons]` — caused the entire addons module to run when targeting ALB controller with `-target`. Removed.

**`context deadline exceeded` hides the real problem.** Helm timeouts look like network issues but are usually `ImagePullBackOff`. Always check `kubectl get pods -A` and `kubectl describe pod <name>` before digging into Helm or networking.

**Incremental edits corrupted `eks-addons/main.tf`.** Kubecost image overrides ended up inside the cluster-autoscaler block. cluster-autoscaler failed on unknown Helm values. Always diff the full file before applying after manual edits.

---

### General

**`assume-dev` credentials expire after 1 hour.** AWS CLI and kubectl calls will start failing with auth errors. Re-run `assume-dev` to refresh.

---

## Fresh Deployment Checklist

- [ ] `TerraformStateRole` exists in management account
- [ ] S3 bucket policy allows child account role ARN
- [ ] `tf-locks` DynamoDB table accessible cross-account
- [ ] Node IAM role has `ecr:CreateRepository` + `ecr:BatchImportUpstreamImage`
- [ ] All image refs overridden to ECR pull-through prefixes
- [ ] Kubecost Helm values use `kubecostModel.image` + `kubecostFrontend.image`
- [ ] Grafana sidecar (`kiwigrid/k8s-sidecar`) overridden to ECR
- [ ] `vpc-cni` healthy before scheduling any other pods
- [ ] `aws-ebs-csi-driver` + IRSA role deployed before Prometheus/Kubecost
- [ ] StorageClass explicitly set in Kubecost Helm values
- [ ] Do not run `assume-dev` before `terraform apply`