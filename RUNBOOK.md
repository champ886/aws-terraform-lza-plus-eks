# RUNBOOK — Issues Encountered, Root Causes & Resolutions

Hard-won notes from building and operating this repo. Read before you touch anything.

---

## Architecture Quick Reference

### VPC Endpoints (replaces NAT Gateway)

| Endpoint | Purpose |
|---|---|
| `ec2` | Node bootstrap via nodeadm — **critical, nodes won't join without this** |
| `eks` | Nodes → control plane API |
| `sts` | IRSA token exchange |
| `ecr.api` | ECR authentication |
| `ecr.dkr` | Image pulls |
| `s3` (Gateway, free) | ECR image layer pulls |
| `autoscaling` | Cluster Autoscaler scale operations |
| `elasticloadbalancing` | ALB controller → ELB API — **required for ALB provisioning** |
| `wafv2` | ALB controller WAF state check — **required or ALB controller times out** |

### ECR Pull Through Cache Prefixes

| Prefix | Upstream | Used By |
|---|---|---|
| `registry-k8s-io` | registry.k8s.io | cluster-autoscaler |
| `ecr-public` | public.ecr.aws | ALB controller, Kubecost |
| `docker-hub` | docker.io | Grafana, Prometheus, Redis, nginx, postgres |
| `quay` | quay.io | Argo CD, prometheus-config-reloader |

---

## Issues & Fixes

---

### 1. Double IAM role assumption → AccessDenied

**Symptom:** `terraform apply` fails with `AccessDenied` or `403 Forbidden` immediately.

**Root cause:** Shell was already running as `OrganizationAccountAccessRole` (via `assume-dev`). `providers.tf` then tried to assume the same role again — AWS rejects chained same-role assumptions.

**Resolution:** Never pre-assume the dev role before running `terraform apply`. The `providers.tf` handles assumption itself. Only run `assume-dev` for direct AWS CLI commands, not for Terraform.

---

### 2. S3 backend `role_arn` wrong placement

**Symptom:** `Error: Invalid argument — role_arn is not expected here`

**Root cause:** `role_arn` was placed at the top level of the `backend "s3"` block instead of inside `assume_role {}`.

**Resolution:**
```hcl
# Wrong
backend "s3" { role_arn = "arn:aws:iam::..." }

# Correct
backend "s3" {
  assume_role = { role_arn = "arn:aws:iam::..." }
}
```

---

### 3. Route table associations planned for destroy

**Symptom:** `terraform plan` shows private route table associations being destroyed.

**Root cause:** `modules/vpc/main.tf` had a `data "aws_subnets"` lookup inside the module. Data sources inside a module that creates the same subnets cause a chicken-and-egg problem — the data source can't find subnets that don't exist yet at plan time, returning an empty list which breaks the associations.

**Resolution:** Replace `data.aws_subnets` with direct resource references:
```hcl
resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id   # ← direct ref
  route_table_id = aws_route_table.private[count.index].id
}
```

---

### 4. Argo CD CRD not found at plan time

**Symptom:** `terraform plan` errors with `API did not recognize GroupVersionKind argoproj.io/v1alpha1/Application`

**Root cause:** `kubernetes_manifest` validates CRD existence at plan time. The Application CRD is installed by the Argo CD Helm chart — which hasn't run yet. Circular dependency.

**Resolution:** Use `gavinbunney/kubectl` provider instead of `kubernetes_manifest`. It defers validation to apply time, allowing the CRD to be installed by Helm in the same run before the Application resource is created.

---

### 5. Dex ImagePullBackOff

**Symptom:** `argocd-dex-server` pod stuck in `ImagePullBackOff`.

**Root cause:** Dex image lives on `ghcr.io` which has no ECR pull-through cache rule. No route to pull from `ghcr.io` in a private cluster.

**Resolution:** Disable Dex — not needed for single-user dev:
```hcl
set { name = "dex.enabled"; value = "false" }
```

---

### 6. Redis ImagePullBackOff

**Symptom:** `argocd-redis` pod stuck in `ImagePullBackOff`.

**Root cause:** Redis image was not overridden to the ECR pull-through cache prefix. Default chart pulls from `docker.io` which has no route in a private cluster.

**Resolution:** Override the Redis image in the Helm release:
```hcl
set {
  name  = "redis.image.repository"
  value = "435321828725.dkr.ecr.ap-southeast-2.amazonaws.com/docker-hub/library/redis"
}
```

---

### 7. Argo CD cannot reach GitHub (private subnets, no internet route)

**Symptom:** `argocd-repo-server` logs show `dial tcp: i/o timeout` to `github.com`. Root app shows `Unknown` sync status.

**Root cause:** Private subnets have no default route to the internet. Security group allows all egress (`0.0.0.0/0`) but without a route table entry, packets are dropped. GitHub does not support AWS PrivateLink so a VPC endpoint is not possible.

**Resolution:** Switch Argo CD source from GitHub HTTPS to ECR OCI registry. Manifests are packaged as a Helm OCI chart and pushed to a private ECR repository by GitHub Actions. Argo CD pulls via the ECR VPC endpoint — fully private, consistent with the rest of the architecture. No NAT Gateway needed.

---

### 8. `yamlencode` producing quoted YAML keys

**Symptom:** Kubernetes rejects the YAML with `couldn't get version/kind; json parse error`.

**Root cause:** `yamlencode` in Terraform wraps keys in double quotes (e.g., `"apiVersion": "v1"`) which is valid YAML but rejected by some Kubernetes parsers.

**Resolution:** Switch to plain heredoc YAML strings in `kubectl_manifest` resources instead of `yamlencode`.

---

### 9. `local-exec` shell credential inheritance failure

**Symptom:** `local-exec` provisioner fails with `AccessDenied` when running `kubectl` or `aws` commands.

**Root cause:** Terraform's assumed IAM role credentials are not automatically exported to the child shell spawned by `local-exec`. The shell inherits the parent process environment which may have different (or no) credentials.

**Resolution:** Remove `local-exec` from Argo CD root app creation. Use `gavinbunney/kubectl` provider with `kubectl_manifest` instead — it runs in Terraform's provider context and inherits credentials correctly.

---

### 10. Argo CD namespace stuck in Terminating

**Symptom:** `kubectl delete namespace argocd` hangs indefinitely. Terraform destroy fails with namespace errors.

**Root cause:** Argo CD Application objects have `resources-finalizer.argocd.argoproj.io` finalizers. The finalizer tells Argo CD to delete all managed Kubernetes resources before the Application is removed. Since Argo CD is being torn down simultaneously, nothing processes the finalizer.

**Resolution:**
```bash
# Remove finalizers from all Application objects
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
  kubectl patch $app -n argocd --type merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
done

# Force remove namespace finalizer
kubectl get namespace argocd -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -

# Delete leftover CRDs
kubectl delete crd \
  applications.argoproj.io \
  applicationsets.argoproj.io \
  appprojects.argoproj.io --ignore-not-found
```

---

### 11. Helm pre-install hook timeout on gitops reapply

**Symptom:** `Error: failed pre-install: timed out waiting for the condition` on `helm_release.argocd`.

**Root cause:** Argo CD CRDs from a previous install were still present. Helm pre-install hooks detected the conflict and timed out waiting for cleanup.

**Resolution:** Delete CRDs and the failed Helm release before reapplying:
```bash
helm uninstall argocd -n argocd --ignore-not-found
kubectl delete crd \
  applications.argoproj.io \
  applicationsets.argoproj.io \
  appprojects.argoproj.io --ignore-not-found
kubectl delete namespace argocd --ignore-not-found
# Force remove if stuck (see issue 10 above)
terraform apply -target=module.gitops
```

---

### 12. ECR OCI push 403 Forbidden

**Symptom:** `helm push` fails with `response status code 403: Forbidden`.

**Root cause (a):** Shell credentials pointed at management account, not dev account. ECR repo is in dev account.

**Resolution (a):** Assume the dev role explicitly before pushing:
```bash
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::435321828725:role/OrganizationAccountAccessRole \
  --role-session-name helm-push-session --output json)
export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')
```

**Root cause (b):** ECR repository policy was too restrictive — only allowed pull actions, not push actions.

**Resolution (b):** Use `ecr:*` on the account root in the repository policy:
```hcl
policy = jsonencode({
  Statement = [{
    Effect    = "Allow"
    Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" }
    Action    = "ecr:*"
  }]
})
```

---

### 13. Helm push path mismatch — repository does not exist

**Symptom:** `helm push` fails with `repository 'gitops/apps/dev/gitops-apps-dev' does not exist`.

**Root cause:** Helm appends the chart name to the OCI path. Pushing to `oci://registry/gitops/apps/dev` with chart name `gitops-apps-dev` results in Helm looking for a repo named `gitops/apps/dev/gitops-apps-dev`. ECR only has `gitops/apps/dev`.

**Resolution:** Name the ECR repo to match what Helm constructs. Rename ECR repo to `gitops-apps-dev` and push to the registry root:
```bash
helm push /tmp/gitops-apps-dev-0.0.1.tgz \
  oci://435321828725.dkr.ecr.ap-southeast-2.amazonaws.com
# Helm constructs: registry/gitops-apps-dev → matches ECR repo name
```

---

### 14. Argo CD `invalid revision 'latest'` with ECR OCI

**Symptom:** Root app shows `ComparisonError: invalid revision 'latest': improper constraint: latest`.

**Root cause:** Argo CD OCI source mode does not support `latest` as a `targetRevision`. It requires an explicit semver tag.

**Resolution:** Use an explicit version in the Application manifest:
```yaml
source:
  targetRevision: "0.0.1"   # must match the pushed chart version
```
Increment this version each time you push a new chart.

---

### 15. Argo CD no ECR credentials → `no basic auth credentials`

**Symptom:** Root app shows `pull access denied, repository does not exist or may require authorization: authorization failed: no basic auth credentials`.

**Root cause:** ECR requires authentication even for private repos within the same account. Argo CD has no ECR credentials by default.

**Resolution:** Create a Kubernetes secret with the `argocd.argoproj.io/secret-type=repository` label:
```bash
ECR_TOKEN=$(aws ecr get-login-password --region ap-southeast-2)
kubectl create secret generic ecr-credentials \
  --namespace argocd \
  --from-literal=type=helm \
  --from-literal=name=ecr-gitops \
  --from-literal=url=435321828725.dkr.ecr.ap-southeast-2.amazonaws.com \
  --from-literal=enableOCI=true \
  --from-literal=username=AWS \
  --from-literal=password=$ECR_TOKEN \
  --dry-run=client -o yaml \
  | kubectl label --local -f - \
      "argocd.argoproj.io/secret-type=repository" \
      --dry-run=client -o yaml \
  | kubectl apply -f -
```
Note: ECR tokens expire every 12 hours. Bake this into `modules/gitops/main.tf` as a `kubernetes_secret` resource using `data.aws_ecr_authorization_token.token.password` so it's refreshed on every `terraform apply`.

---

### 16. Nodes not joining cluster — nodeadm retrying EC2/DescribeInstances

**Symptom:** `kubectl get nodes` returns empty. EC2 console shows instances running. Node console log shows `retrying request EC2/DescribeInstances, attempt 2...3...9...` then stops.

**Root cause:** Node bootstrap process (`nodeadm`) calls `ec2.ap-southeast-2.amazonaws.com` to describe its own instance. The EC2 VPC endpoint was missing or deleted. Without it, the call times out after 9 retries and the node never completes bootstrap.

**Resolution:** Ensure the EC2 VPC endpoint exists. Then terminate the stuck instances — they cannot recover from a failed bootstrap. The node group will replace them automatically:
```bash
aws ec2 terminate-instances \
  --instance-ids <instance-id-1> <instance-id-2> \
  --region ap-southeast-2
kubectl get nodes -w   # watch new nodes join
```

---

### 17. ALB not provisioning — ELB API timeout

**Symptom:** ALB controller logs show `Post "https://elasticloadbalancing.ap-southeast-2.amazonaws.com/": dial tcp: i/o timeout`. No ALB created.

**Root cause:** The ALB controller makes direct HTTPS calls to the ELB API to provision load balancers. No VPC endpoint existed for `elasticloadbalancing` so traffic attempted the public internet and timed out.

**Resolution:** Add the `elasticloadbalancing` VPC endpoint to `modules/vpc-endpoints/main.tf`:
```hcl
resource "aws_vpc_endpoint" "elb" {
  service_name        = "com.amazonaws.${var.region}.elasticloadbalancing"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  ...
}
```

---

### 18. ALB not provisioning — WAFv2 timeout

**Symptom:** After ELB endpoint added, ALB controller logs show `Post "https://wafv2.ap-southeast-2.amazonaws.com/": dial tcp: i/o timeout`.

**Root cause:** ALB controller checks WAFv2 subscription state before finalising ALB creation. No VPC endpoint for `wafv2`, no internet route.

**Resolution (option A):** Add `wafv2` VPC endpoint to `modules/vpc-endpoints/main.tf`.

**Resolution (option B):** Disable WAF and Shield integration in the ALB controller Helm release (correct for clusters with no WAF configured):
```hcl
set { name = "enableShield"; value = "false" }
set { name = "enableWaf";    value = "false" }
set { name = "enableWafv2";  value = "false" }
```

---

### 19. ALB not provisioning — subnet auto-discovery fails

**Symptom:** ALB controller logs show `couldn't auto-discover subnets: unable to resolve at least one subnet (0 match VPC and tags)`.

**Root cause:** Public subnets were missing the required EKS tags. The `aws_ec2_tag` resources were in Terraform state but not actually applied to AWS — state was out of sync after a destroy+rebuild cycle.

**Resolution:** Force-replace the tag resources to rewrite them to AWS:
```bash
terraform apply -var-file=terraform.tfvars \
  -replace=module.vpc_workload.aws_ec2_tag.public_subnet_elb[0] \
  -replace=module.vpc_workload.aws_ec2_tag.public_subnet_elb[1] \
  -replace=module.vpc_workload.aws_ec2_tag.public_subnet_cluster[0] \
  -replace=module.vpc_workload.aws_ec2_tag.public_subnet_cluster[1]
```
Required tags on public subnets:
- `kubernetes.io/role/elb = 1`
- `kubernetes.io/cluster/<cluster-name> = shared`

---

### 20. PostgreSQL Bitnami chart timeout — no internet

**Symptom:** `postgresql-helm` Argo CD Application shows `helm pull https://charts.bitnami.com/bitnami postgresql failed timeout after 1m30s`.

**Root cause:** Argo CD was configured to pull the Bitnami Helm chart directly from `charts.bitnami.com`. Private subnets have no internet route.

**Resolution:** Switch from Bitnami Helm source to raw Kubernetes manifests in `gitops/apps/dev/postgresql/postgresql.yaml`. Use the `docker-hub/library/postgres:15` image via ECR pull-through cache. No external chart repository needed.

---

### 21. ECR repo destroy blocked — repository not empty

**Symptom:** `terraform destroy` fails with `RepositoryNotEmptyException: cannot be deleted because it still contains images`.

**Root cause:** Helm pushed a chart to the ECR OCI repo. Terraform's default `aws_ecr_repository` resource refuses to delete repos with images.

**Resolution:** Add `force_delete = true` to the ECR repo resource:
```hcl
resource "aws_ecr_repository" "gitops" {
  force_delete = true
  ...
}
```
For an existing destroy, delete manually first:
```bash
aws ecr delete-repository \
  --repository-name gitops-apps-dev \
  --region ap-southeast-2 \
  --force
```

---

### 22. Session token expiry during long apply sequences

**Symptom:** Mid-apply errors like `ExpiredTokenException` or `403 Forbidden` on S3 state operations.

**Root cause:** AWS STS session tokens issued via `assume-role` expire after 1 hour by default. Long Terraform apply sequences exceed this.

**Resolution:** Re-assume the role and re-export credentials:
```bash
CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::435321828725:role/OrganizationAccountAccessRole \
  --role-session-name terraform-session --output json)
export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.Credentials.SessionToken')
```

---

### 23. GitHub OIDC provider not found

**Symptom:** `terraform apply` on `module.github_actions_role` fails with `finding IAM OIDC Provider by url: not found`.

**Root cause:** The GitHub OIDC provider (`token.actions.githubusercontent.com`) did not exist in the dev account. The module used a `data` source which requires the resource to already exist.

**Resolution:** Replace the `data` source with a `resource` block to create the OIDC provider:
```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

---

## Deployment Checklist (Fresh Start)

- [ ] TerraformStateRole exists in management account
- [ ] S3 state bucket exists with versioning enabled
- [ ] Do NOT pre-assume dev role before `terraform apply`
- [ ] Apply VPC before EKS
- [ ] All 9 VPC endpoints applied (including `elasticloadbalancing` and `wafv2`)
- [ ] Node IAM role has `ecr:CreateRepository` + `ecr:BatchImportUpstreamImage`
- [ ] All image refs overridden to ECR pull-through prefixes
- [ ] Dex disabled in Argo CD Helm values
- [ ] Redis image overridden to `docker-hub/library/redis`
- [ ] ECR OCI repo named `gitops-apps-dev` (not `gitops/apps/dev`)
- [ ] Chart pushed with explicit semver tag (not `latest`)
- [ ] Argo CD ECR credentials secret created in `argocd` namespace
- [ ] `force_delete = true` on ECR OCI repo resource
- [ ] ALB controller has WAF/Shield disabled
- [ ] Public subnets tagged with `kubernetes.io/role/elb=1` and `kubernetes.io/cluster/<name>=shared`
- [ ] Session token refreshed if apply takes > 1 hour

## Clean Destroy Checklist

- [ ] Remove Argo CD Application finalizers
- [ ] Force-remove `argocd` namespace if stuck terminating
- [ ] Delete Argo CD CRDs manually
- [ ] Force-delete ECR OCI repo (`aws ecr delete-repository --force`)
- [ ] `terraform destroy` EKS environment
- [ ] `terraform destroy` VPC environment