locals {
  name            = ""
  region          = ""
  cluster_domain  = ""
  cluster_version = "1.23"
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)

  vpc = {
    cidr                = ""
    public_access_cidrs = []
  }

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/alex-souslik/eks-gitops"
  }
}
