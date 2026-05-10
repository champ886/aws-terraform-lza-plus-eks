# -----------------------------------------------
# DATA SOURCES
# Reads existing dev VPC created by dev/vpc
# -----------------------------------------------
data "aws_vpc" "dev_workload" {
  provider   = aws.workload
  cidr_block = "10.0.0.0/16"
}

data "aws_subnets" "private" {
  provider = aws.workload
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.dev_workload.id]
  }
  tags = {
    Type = "Private"
  }
}

data "aws_subnets" "public" {
  provider = aws.workload
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.dev_workload.id]
  }
  tags = {
    Type = "Public"
  }
}

data "aws_caller_identity" "current" {
  provider = aws.workload
}

# -----------------------------------------------
# ECR PULL THROUGH CACHE
# Step 0 — deploy before EKS so images are
# available when nodes first start pulling
# terraform apply -target=module.ecr_pull_through
# -----------------------------------------------
module "ecr_pull_through" {
  source = "../../../modules/ecr-pull-through"

  providers = {
    aws.workload = aws.workload
  }

  environment         = var.environment
  docker_hub_username = var.docker_hub_username
  docker_hub_token    = var.docker_hub_token
}

# -----------------------------------------------
# EKS CLUSTER MODULE
# Step 1 — deploy this first on its own
# terraform apply -target=module.eks
# -----------------------------------------------
module "eks" {
  source = "../../../modules/eks"

  providers = {
    aws = aws.workload
  }

  cluster_name                         = "lean-dev"
  environment                          = "dev"
  kubernetes_version                   = "1.32"
  vpc_id                               = data.aws_vpc.dev_workload.id
  private_subnet_ids                   = data.aws_subnets.private.ids
  public_subnet_ids                    = data.aws_subnets.public.ids
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  node_instance_types                  = ["t3.medium"]
  node_desired_size                    = 2
  node_min_size                        = 1
  node_max_size                        = 5
}

# -----------------------------------------------
# EKS ADDONS MODULE
# Step 2 — core addons + autoscaler + kubecost
# terraform apply -target=module.eks_addons
# -----------------------------------------------
module "eks_addons" {
  source = "../../../modules/eks-addons"

  providers = {
    aws.workload = aws.workload
    helm         = helm
    kubernetes   = kubernetes
  }

  cluster_name              = module.eks.cluster_name
  environment               = "dev"
  aws_region                = "ap-southeast-2"
  aws_account_id            = "435321828725"
  cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn

  depends_on = [module.eks]
}

# -----------------------------------------------
# ALB CONTROLLER MODULE
# Step 3 — deploy after core addons
# terraform apply -target=module.alb_controller
# -----------------------------------------------
module "alb_controller" {
  source = "../../../modules/alb-controller"

  providers = {
    aws.workload = aws.workload
    helm         = helm
  }

  cluster_name              = module.eks.cluster_name
  environment               = "dev"
  aws_region                = "ap-southeast-2"
  vpc_id                    = data.aws_vpc.dev_workload.id
  cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn

  depends_on = [module.eks_addons]
}

# -----------------------------------------------
# GITOPS — ARGO CD
# Step 4 — deploy after ALB controller
# Terraform installs Argo CD via Helm and creates
# the ECR OCI repo for GitOps manifests
# Argo CD reads manifests from ECR, not GitHub —
# fully private via existing ECR VPC endpoint
# terraform apply -target=module.gitops
# -----------------------------------------------
module "gitops" {
  source = "../../../modules/gitops"

  providers = {
    aws.workload = aws.workload
    helm         = helm
    kubernetes   = kubernetes
    kubectl      = kubectl
  }

  environment    = "dev"
  aws_account_id = "435321828725"
  aws_region     = "ap-southeast-2"

  depends_on = [module.alb_controller]
}

# -----------------------------------------------
# GITHUB ACTIONS ROLE
# Allows GitHub Actions to push GitOps manifests
# to the ECR OCI repo via OIDC — no stored keys
# -----------------------------------------------
module "github_actions_role" {
  source = "../../../modules/github-actions-role"

  providers = {
    aws = aws.workload
  }

  environment        = "dev"
  ecr_repository_arn = module.gitops.gitops_ecr_repo_arn

  depends_on = [module.gitops]
}