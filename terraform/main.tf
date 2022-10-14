provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}

data "aws_availability_zones" "available" {}

data "aws_eks_addon_version" "default" {
  for_each           = toset(["coredns", "aws-ebs-csi-driver", "kube-proxy", "vpc-cni"])
  addon_name         = each.value
  kubernetes_version = local.cluster_version
}

module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints"

  cluster_name    = local.name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access_cidrs = local.vpc.public_access_cidrs

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets
  public_subnet_ids  = module.vpc.public_subnets

  managed_node_groups = {
    mg_5 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["m5.large"]
      subnet_ids      = module.vpc.private_subnets

      desired_size = 3
      max_size     = 5
      min_size     = 1
    }
  }

  tags = local.tags
}

module "eks_blueprints_kubernetes_addons" {
  source     = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/kubernetes-addons"
  depends_on = [module.eks_blueprints.managed_node_groups]

  eks_cluster_domain   = local.cluster_domain
  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version

  enable_argocd = true
  argocd_helm_config = {
    values = [<<-EOT
    server:
      ingress:
        enabled: true
        https: true
        annotations:
          kubernetes.io/ingress.class: "nginx"
          nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
          nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
        hosts:
            - argocd-${local.name}.${local.cluster_domain}
    EOT
    ]
    set_sensitive = [
      {
        name  = "configs.secret.argocdServerAdminPassword"
        value = bcrypt(data.aws_secretsmanager_secret_version.admin_password_version.secret_string)
      }
    ]
  }

  argocd_manage_add_ons = true
  argocd_applications = {
    addons = {
      path     = "helm/chart"
      repo_url = "github.com/alex-souslik/eks-gitops.git"
      values = {
        clusterAutoscaler = { enable = true },
        externalDns       = { enable = true },
        ingressNginx      = { enable = true },
        metricsServer     = { enable = true }
      }
      add_on_application  = true
    }

  }

  enable_amazon_eks_coredns = true
  amazon_eks_coredns_config = {
    addon_version     = data.aws_eks_addon_version.default["coredns"].version
    resolve_conflicts = "OVERWRITE"
    tags              = local.tags
  }

  enable_amazon_eks_aws_ebs_csi_driver = true
  amazon_eks_aws_ebs_csi_driver_config = {
    addon_version     = data.aws_eks_addon_version.default["aws-ebs-csi-driver"].version
    resolve_conflicts = "OVERWRITE"
    tags              = local.tags
  }

  enable_amazon_eks_kube_proxy = true
  amazon_eks_kube_proxy_config = {
    addon_version     = data.aws_eks_addon_version.default["kube-proxy"].version
    resolve_conflicts = "OVERWRITE"
    tags              = local.tags
  }

  enable_amazon_eks_vpc_cni = true
  amazon_eks_vpc_cni_config = {
    addon_version     = data.aws_eks_addon_version.default["vpc-cni"].version
    resolve_conflicts = "OVERWRITE"
    tags              = local.tags
  }

  enable_cluster_autoscaler = true
  enable_chaos_mesh         = true
  enable_external_dns       = true
  enable_ingress_nginx      = true
  enable_metrics_server     = true

  tags = local.tags
}

resource "random_password" "argocd" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "arogcd" {
  name                    = "argocd-${local.name}"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
}

resource "aws_secretsmanager_secret_version" "arogcd" {
  secret_id     = aws_secretsmanager_secret.arogcd.id
  secret_string = random_password.argocd.result
}

data "aws_secretsmanager_secret_version" "admin_password_version" {
  secret_id = aws_secretsmanager_secret.arogcd.id

  depends_on = [aws_secretsmanager_secret_version.arogcd]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = local.vpc.cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc.cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc.cidr, 8, k + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }

  tags = local.tags
}