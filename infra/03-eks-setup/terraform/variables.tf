variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "dokandar"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "cluster_version" {
  description = <<-EOT
    EKS Kubernetes version. NOTE: AWS EKS does NOT allow skipping minor versions
    on an EXISTING cluster — you must step 1.31 -> 1.32 -> ... -> 1.35 one at a
    time (change this var, apply, repeat). A brand-new cluster can be created at
    1.35 directly.
  EOT
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = "The 2 worker nodes run ALL services — size accordingly."
  type        = string
  default     = "c5.2xlarge" # 4 vCPU / 16 GiB each
}

variable "jump_instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "subnet_cidrs" {
  description = "Two PRIVATE subnets across two AZs (inside 01's 10.0.0.0/16; clear of 10.0.1.0/24 VPN, 10.0.2.0/24 runner, 10.0.11.0/24 utilities)."
  type = object({
    private_a = string
    private_b = string
  })
  default = {
    private_a = "10.0.12.0/24"
    private_b = "10.0.13.0/24"
  }
}
