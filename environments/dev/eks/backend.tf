terraform {
  backend "s3" {
    bucket         = "tf-state-landing-zone-champ-001"
    key            = "aws-lza/dev/eks/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    use_lockfile   = true

    assume_role = {
      role_arn = "arn:aws:iam::501562869247:role/TerraformStateRole"
    }
  }
}