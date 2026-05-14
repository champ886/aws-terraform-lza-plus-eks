# aws-terraform-lza-plus-eks

A production-ready, cost-optimised EKS pattern for AWS Landing Zone — fully private nodes, no NAT Gateway, GitOps-driven workload delivery via Argo CD and ECR OCI.

This repo is a working reference architecture for teams running private EKS on AWS in a real environment. It is not a tutorial. Every component exists because it was needed, and every cost was interrogated before it was accepted.

---

## Who This Is For

Teams that are:

- Running EKS in a regulated or security-conscious environment and need fully private node networking
- Paying NAT Gateway bills and wondering if there is a better way
- Trying to get cost visibility and autoscaling working without adding complexity for its own sake
- Deploying across multiple AWS accounts (dev + prod) with proper state isolation
- Wanting a GitOps workflow where Terraform manages infrastructure and Argo CD manages workloads

If you are building a demo or learning environment, this is probably more than you need. If you are running workloads that matter, read on.

---

## The Core Idea

Most EKS setups assume a NAT Gateway, public subnets, and open internet access from nodes. That approach works, but it has a cost: roughly $35–70/month per AZ just for the gateway, plus data transfer, plus the attack surface of nodes that can initiate outbound internet connections.

This repo replaces NAT Gateway entirely with two cheaper, more secure alternatives:

- **VPC Interface Endpoints (PrivateLink)** — nodes talk to AWS APIs over the private AWS network. No internet required.
- **ECR Pull Through Cache** — nodes pull container images from a private ECR registry that proxies and caches upstream registries. No DockerHub hits from production nodes.

Workload delivery follows a GitOps split:

<table>
<thead>
<tr>
<th>Layer</th>
<th>Tool</th>
<th>Manages</th>
</tr>
</thead>
<tbody>
<tr>
<td>VPC, EKS, IAM, add-ons, ALB controller, Argo CD</td>
<td>Terraform</td>
<td>Infrastructure</td>
</tr>
<tr>
<td>Sample app, PostgreSQL, all workloads</td>
<td>Argo CD</td>
<td>Applications</td>
</tr>
</tbody>
</table>

Argo CD reads manifests from a **private ECR OCI repository** — not directly from GitHub. This keeps all traffic fully private via the ECR VPC endpoint and eliminates the need for a NAT Gateway or GitHub VPC endpoint.

---

## What This Repo Provisions

<table>
<thead>
<tr>
<th>Component</th>
<th>Module</th>
<th>Purpose</th>
</tr>
</thead>
<tbody>
<tr>
<td>VPC + Subnets</td>
<td><code>modules/vpc</code></td>
<td>Public and private subnets with EKS subnet tags</td>
</tr>
<tr>
<td>VPC Interface Endpoints</td>
<td><code>modules/vpc-endpoints</code></td>
<td>Private connectivity from nodes to AWS APIs — replaces NAT Gateway</td>
</tr>
<tr>
<td>ECR Pull Through Cache</td>
<td><code>modules/ecr-pull-through</code></td>
<td>Proxy and cache for upstream registries</td>
</tr>
<tr>
<td>EKS Cluster</td>
<td><code>modules/eks</code></td>
<td>Private EKS control plane + managed node groups</td>
</tr>
<tr>
<td>EKS Add-ons</td>
<td><code>modules/eks-addons</code></td>
<td>vpc-cni, ebs-csi-driver, cluster-autoscaler, Kubecost, Prometheus, Grafana</td>
</tr>
<tr>
<td>ALB Controller</td>
<td><code>modules/alb-controller</code></td>
<td>Provisions ALBs from Kubernetes Ingress objects</td>
</tr>
<tr>
<td>GitOps (Argo CD)</td>
<td><code>modules/gitops</code></td>
<td>Installs Argo CD, creates ECR OCI repo, applies root Application</td>
</tr>
<tr>
<td>GitHub Actions Role</td>
<td><code>modules/github-actions-role</code></td>
<td>OIDC IAM role for CI to push GitOps manifests to ECR</td>
</tr>
<tr>
<td>Terraform State Role</td>
<td><code>modules/terraform-state-role</code></td>
<td>Cross-account IAM role for S3 state access</td>
</tr>
</tbody>
</table>

---

## Architecture

Internet → ALB (public subnet) ← provisioned by ALB controller from Ingress objects → Pods (private subnets) connected to:

**VPC Interface Endpoints (PrivateLink)**
- `ec2` → Node bootstrap (nodeadm)
- `eks` → EKS control plane API
- `sts` → IRSA token exchange
- `ecr.api` → ECR authentication
- `ecr.dkr` → Image pulls
- `s3` (Gateway, free) → Image layer pulls
- `autoscaling` → Cluster Autoscaler
- `elasticloadbalancing` → ALB controller ELB API calls
- `wafv2` → ALB controller WAF state check

**Private ECR**
- `registry-k8s-io` → cluster-autoscaler
- `ecr-public` → ALB controller, Kubecost
- `docker-hub` → Grafana, Prometheus, Redis, nginx, postgres
- `quay` → Argo CD, prometheus-config-reloader
- `gitops-apps-dev` → GitOps OCI chart (pushed by GitHub Actions)

**No traffic leaves the AWS network. No NAT Gateway. No internet gateway on node subnets.**

---

## GitOps Flow

git push to main → GitHub Actions (.github/workflows/push-gitops-manifests.yml) packages gitops/apps/dev/ as a Helm OCI chart and pushes to ECR OCI repo via OIDC (no stored AWS keys) → ECR OCI repo: 435321828725.dkr.ecr.ap-southeast-2.amazonaws.com/gitops-apps-dev → Argo CD repo-server (polls every 3 minutes via ECR VPC endpoint) reads chart and extracts YAML manifests → Kubernetes API creates/updates Deployments, Services, Ingresses → ALB controller sees new Ingress and provisions ALB → traffic flows

---

## Repo Structure

```text
aws-terraform-lza-plus-eks/
├── .github/
│   └── workflows/
│       └── push-gitops-manifests.yml  ← CI: packages and pushes manifests to ECR OCI
│
├── environments/
│   └── dev/
│       ├── vpc/  ← VPC + endpoints (apply first)
│       └── eks/  ← EKS + all modules (apply second)
│
├── modules/
│   ├── vpc/                   ← VPC, subnets, route tables, subnet tags
│   ├── vpc-endpoints/         ← All VPC interface endpoints
│   ├── ecr-pull-through/      ← ECR pull-through cache rules
│   ├── eks/                   ← EKS cluster + node group + OIDC
│   ├── eks-addons/            ← Core add-ons + Kubecost + autoscaler
│   ├── alb-controller/        ← AWS Load Balancer Controller
│   ├── gitops/                ← Argo CD + ECR OCI repo + root Application
│   ├── github-actions-role/   ← OIDC IAM role for CI ECR push
│   └── terraform-state-role/  ← Cross-account state IAM role
│
└── gitops/
    └── apps/
        └── dev/
            ├── sample-app-app.yaml    ← Argo CD Application: sample-app
            ├── postgresql-app.yaml    ← Argo CD Application: postgresql
            ├── sample-app/            ← Raw YAML: Deployment, Service, Ingress
            └── postgresql/            ← Raw YAML: Deployment, Service, Secret
```

---

## VPC Endpoints Required

<table>
<thead>
<tr>
<th>Endpoint</th>
<th>Type</th>
<th>Purpose</th>
</tr>
</thead>
<tbody>
<tr>
<td><code>ec2</code></td>
<td>Interface</td>
<td>Node bootstrap via nodeadm — nodes will not join without this</td>
</tr>
<tr>
<td><code>eks</code></td>
<td>Interface</td>
<td>EKS control plane API</td>
</tr>
<tr>
<td><code>sts</code></td>
<td>Interface</td>
<td>IRSA token exchange</td>
</tr>
<tr>
<td><code>ecr.api</code></td>
<td>Interface</td>
<td>ECR authentication</td>
</tr>
<tr>
<td><code>ecr.dkr</code></td>
<td>Interface</td>
<td>Image pulls</td>
</tr>
<tr>
<td><code>s3</code></td>
<td>Gateway (free)</td>
<td>ECR image layer pulls</td>
</tr>
<tr>
<td><code>autoscaling</code></td>
<td>Interface</td>
<td>Cluster Autoscaler</td>
</tr>
<tr>
<td><code>elasticloadbalancing</code></td>
<td>Interface</td>
<td>ALB controller ELB API calls — required for ALB provisioning</td>
</tr>
<tr>
<td><code>wafv2</code></td>
<td>Interface</td>
<td>ALB controller WAF state check — required or controller times out</td>
</tr>
</tbody>
</table>

**Missing any of these causes silent failures** — nodes will not join, images will not pull, or ALBs will not provision.

---

## ECR Pull Through Cache Prefixes

<table>
<thead>
<tr>
<th>ECR Prefix</th>
<th>Upstream Registry</th>
<th>Used By</th>
</tr>
</thead>
<tbody>
<tr>
<td><code>registry-k8s-io</code></td>
<td>registry.k8s.io</td>
<td>cluster-autoscaler</td>
</tr>
<tr>
<td><code>ecr-public</code></td>
<td>public.ecr.aws</td>
<td>ALB controller, Kubecost</td>
</tr>
<tr>
<td><code>docker-hub</code></td>
<td>docker.io</td>
<td>Grafana, Prometheus, Redis, nginx, postgres</td>
</tr>
<tr>
<td><code>quay</code></td>
<td>quay.io</td>
<td>Argo CD, prometheus-config-reloader</td>
</tr>
</tbody>
</table>

The node IAM role must have `ecr:CreateRepository` and `ecr:BatchImportUpstreamImage`. Without these, first pulls fail silently with `ImagePullBackOff`.

---

## Cost Model

### What you are not paying for

<table>
<thead>
<tr>
<th>Removed</th>
<th>Typical Monthly Cost</th>
</tr>
</thead>
<tbody>
<tr>
<td>NAT Gateway (per AZ)</td>
<td>~$35 plus data transfer</td>
</tr>
<tr>
<td>Public ECR / Docker Hub data transfer</td>
<td>Variable</td>
</tr>
<tr>
<td>Oversized always-on node groups</td>
<td>Significant at idle</td>
</tr>
</tbody>
</table>

### What replaces it

<table>
<thead>
<tr>
<th>Replacement</th>
<th>Cost</th>
</tr>
</thead>
<tbody>
<tr>
<td>VPC Interface Endpoints (9 endpoints)</td>
<td>~$7/month each — fixed and predictable</td>
</tr>
<tr>
<td>S3 Gateway Endpoint</td>
<td>Free</td>
</tr>
<tr>
<td>ECR Pull Through Cache</td>
<td>Storage only after first pull</td>
</tr>
<tr>
<td>Cluster Autoscaler</td>
<td>Free — runs on existing nodes</td>
</tr>
</tbody>
</table>

---

## Environments

<table>
<thead>
<tr>
<th></th>
<th>Dev</th>
</tr>
</thead>
<tbody>
<tr>
<td>Account ID</td>
<td>435321828725</td>
</tr>
<tr>
<td>Region</td>
<td>ap-southeast-2</td>
</tr>
<tr>
<td>VPC CIDR</td>
<td>10.0.0.0/16</td>
</tr>
<tr>
<td>Cluster</td>
<td>lean-dev</td>
</tr>
<tr>
<td>State key prefix</td>
<td><code>aws-lza/dev/</code></td>
</tr>
</tbody>
</table>

---

## Terraform State

State is stored in S3 with file-based locking (`use_lockfile = true` — no DynamoDB required). Access uses cross-account role assumption. No credentials are stored in code.

```hcl
terraform {
  backend "s3" {
    bucket       = "tf-state-landing-zone-champ-001"
    key          = "aws-lza/dev/eks/terraform.tfstate"
    region       = "ap-southeast-2"
    use_lockfile = true

    assume_role = {
      role_arn = "arn:aws:iam::501562869247:role/TerraformStateRole"
    }
  }
}
```

> **⚠️ Do not pre-assume the dev role before `terraform apply`.** `providers.tf` handles role assumption itself. Pre-assuming causes double assumption and `AccessDenied`.

---

## Deployment Order

**Order is not optional.** Hard dependencies exist between layers.

### Step 1: VPC

```bash
cd environments/dev/vpc
terraform init
terraform apply -var-file=terraform.tfvars
```

### Step 2: EKS (targeted in order)

```bash
cd environments/dev/eks
terraform init
terraform apply -var-file=terraform.tfvars -target=module.ecr_pull_through
terraform apply -var-file=terraform.tfvars -target=module.eks
terraform apply -var-file=terraform.tfvars -target=module.eks_addons
terraform apply -var-file=terraform.tfvars -target=module.alb_controller
terraform apply -var-file=terraform.tfvars -target=module.gitops
terraform apply -var-file=terraform.tfvars -target=module.github_actions_role
```

### Step 3: Push initial GitOps manifests to ECR OCI

```bash
VERSION=0.0.1
mkdir -p /tmp/gitops-chart/templates
cp -r gitops/apps/dev/* /tmp/gitops-chart/templates/

cat > /tmp/gitops-chart/Chart.yaml <<EOF
apiVersion: v2
name: gitops-apps-dev
description: GitOps manifests for dev
type: application
version: ${VERSION}
EOF

helm package /tmp/gitops-chart --version ${VERSION} --destination /tmp/

aws ecr get-login-password --region ap-southeast-2 \
  | helm registry login --username AWS --password-stdin \
      435321828725.dkr.ecr.ap-southeast-2.amazonaws.com

helm push /tmp/gitops-apps-dev-${VERSION}.tgz \
  oci://435321828725.dkr.ecr.ap-southeast-2.amazonaws.com
```

### Step 4: Create Argo CD ECR credentials secret

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

### Step 5: Verify

```bash
kubectl get applications -n argocd
kubectl get ingress -n sample-app -w

ALB=$(kubectl get ingress sample-app -n sample-app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$ALB
# Expected: HTTP Status: 200
```

---

## Clean Destroy

```bash
# Remove Argo CD finalizers
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
  kubectl patch $app -n argocd --type merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
done

kubectl get namespace argocd -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f - 2>/dev/null

kubectl delete crd \
  applications.argoproj.io \
  applicationsets.argoproj.io \
  appprojects.argoproj.io --ignore-not-found

# Force delete ECR OCI repo
aws ecr delete-repository \
  --repository-name gitops-apps-dev \
  --region ap-southeast-2 --force

# Destroy EKS then VPC
cd environments/dev/eks
terraform destroy -var-file=terraform.tfvars

cd environments/dev/vpc
terraform destroy -var-file=terraform.tfvars
```

---

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured for the management account
- `jq` installed
- `helm` >= 3.15
- `TerraformStateRole` deployed in the management account
- S3 state bucket created with versioning enabled
- GitHub OIDC provider in the dev account (created by `modules/github-actions-role`)

---

## Further Reading

See `RUNBOOK.md` for a full account of every issue encountered during build and operation — root causes, fixes, and lessons learned. Most of the hard problems are already solved there.

---

## License

MIT
