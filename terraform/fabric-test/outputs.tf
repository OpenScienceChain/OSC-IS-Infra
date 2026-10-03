output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value     = aws_eks_cluster.this.endpoint
  sensitive = true
}

output "node_group_name" {
  value = aws_eks_node_group.fabric.node_group_name
}

output "expires_at" {
  value = var.expires_at
}

output "estimated_hourly_compute_usd" {
  description = "2026-07-31 estimate: EKS standard control plane plus three on-demand t3.large nodes in us-west-2; excludes EBS and traffic."
  value       = 0.3496
}
