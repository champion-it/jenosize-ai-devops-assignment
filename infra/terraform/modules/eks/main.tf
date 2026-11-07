# EKS cluster.
#
# Nodes run on Fargate rather than EC2: there is no node group to size,
# patch or drain, and billing is per pod rather than per idle instance. For
# a cluster whose job is to run a handful of pods, managing nodes is work
# with no payoff.
#
# The cost that does not go away is the control plane, which bills whether
# or not anything is scheduled. That is the price of this path and it is
# stated in the cluster README rather than discovered on an invoice.

data "aws_partition" "current" {}

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_cluster" "main" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)

    # Private access is what the workloads use. The public endpoint stays on
    # because CI has no fixed egress address, and is narrowed by
    # public_access_cidrs rather than left open.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # Control plane audit logging. Without it there is no record of who
  # changed what in the cluster.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    # API rather than the aws-auth ConfigMap: access is IAM, managed by
    # Terraform, and visible in the plan instead of in a ConfigMap someone
    # edited by hand.
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags       = var.tags
  depends_on = [aws_cloudwatch_log_group.cluster]
}

# Maps a Kubernetes service account to an IAM role, so a pod gets AWS
# credentials without a key existing anywhere. The same reasoning as the
# federation used for CI.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Fargate
# ---------------------------------------------------------------------------

resource "aws_iam_role" "fargate" {
  name = "${var.name}-fargate"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "fargate" {
  role       = aws_iam_role.fargate.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# One profile per namespace that runs pods. Fargate only schedules pods
# whose namespace matches a profile, so a namespace without one silently
# never starts: the profiles are the list of namespaces this cluster serves.
resource "aws_eks_fargate_profile" "main" {
  for_each = toset(var.fargate_namespaces)

  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = replace(each.value, "/[^a-zA-Z0-9-]/", "-")
  pod_execution_role_arn = aws_iam_role.fargate.arn
  # Fargate pods need a route out, so private subnets only.
  subnet_ids = var.private_subnet_ids

  selector {
    namespace = each.value
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Add-ons
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "core" {
  for_each = toset(["coredns", "kube-proxy", "vpc-cni"])

  cluster_name  = aws_eks_cluster.main.name
  addon_name    = each.value
  addon_version = null

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags       = var.tags
  depends_on = [aws_eks_fargate_profile.main]
}
