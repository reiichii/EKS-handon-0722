output "node_iam_role_name" {
  description = "The name of the IAM role for the Karpenter node"
  value       = module.karpenter.node_iam_role_name
}

output "queue_name" {
  description = "The name of the SQS queue"
  value       = module.karpenter.queue_name
}