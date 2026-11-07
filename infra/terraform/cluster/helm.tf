# Platform components installed into the cluster.
#
# Terraform owns them rather than a bootstrap script because they are part
# of what the cluster *is*: without the load balancer controller an Ingress
# does nothing, and without Argo Rollouts a Rollout object is inert.

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_lb_controller.role_arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.network.vpc_id
  }

  depends_on = [module.eks]
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.argo_rollouts_chart_version
  namespace        = "argo-rollouts"
  create_namespace = true

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_rollouts.role_arn
  }

  # The dashboard is how a canary in progress is actually watched. It has no
  # authentication of its own, so it is cluster-internal and reached by port
  # forward rather than exposed.
  set {
    name  = "dashboard.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}
