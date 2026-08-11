output "vpc_id" {
  description = "The VPC (owned by 01-vpn-setup) the platform was deployed into."
  value       = local.vpc_id
}

output "runner_public_ip" {
  description = "Public/Elastic IP of the GitLab runner."
  value       = aws_eip.runner.public_ip
}

output "utilities_private_ip" {
  description = "Private IP of the utilities host (reachable over the VPN)."
  value       = aws_instance.this["utilities"].private_ip
}

output "ssh_commands" {
  description = "SSH commands (runner direct; utilities over the VPN)."
  value = {
    gitlab-runner = "ssh -i ${local_sensitive_file.pem["gitlab-runner"].filename} ubuntu@${aws_eip.runner.public_ip}"
    utilities     = "ssh -i ${local_sensitive_file.pem["utilities"].filename} ubuntu@${aws_instance.this["utilities"].private_ip}  # connect the VPN first"
  }
}

output "ssh_key_paths" {
  description = "Local paths to each instance's private key."
  value       = { for k, f in local_sensitive_file.pem : k => f.filename }
}

output "ecr_registry" {
  description = "ECR registry host for docker login."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "ECR repository URLs (docker push/pull targets)."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "kms_secrets_key_arn" {
  description = "KMS key ARN for application secrets."
  value       = aws_kms_key.secrets.arn
}
