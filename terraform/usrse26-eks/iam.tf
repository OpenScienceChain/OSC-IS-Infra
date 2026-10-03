locals {
  workload_pod_identity_roles = {
    api-gateway                    = var.runtime_role_arns.api_gateway
    postgres                       = var.runtime_role_arns.postgres
    submission-worker              = var.runtime_role_arns.submission_worker
    submission-listener            = var.runtime_role_arns.submission_listener
    ledger-gateway-nsg             = var.runtime_role_arns.ledger_gateway_nsg
    ledger-gateway-citizen-science = var.runtime_role_arns.ledger_gateway_citizen_science
  }
}

resource "aws_eks_pod_identity_association" "workload_secrets" {
  for_each = local.workload_pod_identity_roles

  cluster_name    = aws_eks_cluster.experiment.name
  namespace       = "osc-apps"
  service_account = each.key
  role_arn        = each.value

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = aws_eks_cluster.experiment.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = var.runtime_role_arns.alb_controller

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.experiment.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = var.runtime_role_arns.ebs_csi

  depends_on = [aws_eks_addon.pod_identity]
}
