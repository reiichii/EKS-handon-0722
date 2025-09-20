terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.34, < 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.9, < 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = local.region
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

################################################################################
# Common data/locals
################################################################################

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name   = "eks-handson"
  region = "ap-northeast-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    user = var.user != "" ? var.user : "default-user"
  }
}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.name
  cluster_version = "1.33"

  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    ops = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["m5.large", "t3.medium"]
      capacity_type  = "SPOT"

      min_size     = 2
      max_size     = 4
      desired_size = 3

      labels = {
        "workload-type" = "ops"
      }
    }
  }

  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

################################################################################
# ArgoCD Module
################################################################################

module "argocd" {
  source = "./modules/argocd"

  providers = {
    kubernetes = kubernetes
  }

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_version                    = module.eks.cluster_version
  oidc_provider_arn                  = module.eks.oidc_provider_arn
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  region                             = local.region
  account_id                         = data.aws_caller_identity.current.account_id
  vpc_id                             = module.vpc.vpc_id
  kubernetes_version                 = "1.28"

  addons = {
    enable_aws_load_balancer_controller = true
    enable_metrics_server               = true
    enable_argocd                       = true
    enable_karpenter                    = true
  }

  tags = local.tags

  depends_on = [module.eks]
}

################################################################################
# Karpenter Module (Commented out - Using ArgoCD addons instead)
################################################################################

# module "karpenter" {
#   source = "./modules/karpenter"
#
#   cluster_name           = module.eks.cluster_name
#   cluster_endpoint       = module.eks.cluster_endpoint
#   oidc_provider_arn      = module.eks.oidc_provider_arn
#   node_security_group_id = module.eks.node_security_group_id
#
#   tags = local.tags
#
#   depends_on = [module.argocd]
# }

################################################################################
# Outputs
################################################################################

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

# 以下必要ないかも？

output "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

# Karpenter module outputs (Commented out - Using ArgoCD addons instead)
# output "karpenter_node_iam_role_name" {
#   description = "The name of the IAM role for the Karpenter node"
#   value       = module.karpenter.node_iam_role_name
# }

# output "karpenter_queue_name" {
#   description = "The name of the SQS queue"
#   value       = module.karpenter.queue_name
# }
