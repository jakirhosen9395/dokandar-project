module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = local.vpc_id
  subnet_ids = [for s in aws_subnet.private : s.id]

  # API endpoint stays public so kubectl works from your laptop without the VPN;
  # every NODE is private. Set to false + private_access if you want VPN-only kubectl.
  cluster_endpoint_public_access           = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  # Allow the jump server to reach the EKS private API endpoint on port 443.
  # Without this rule the cluster SG blocks the jump server even though outbound
  # from the jump SG is fully open.
  cluster_security_group_additional_rules = {
    jump_server_api = {
      description              = "Jump server to EKS API (private endpoint)"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.jump.id
    }
  }

  # The jump server is the sole control host: grant its instance-profile role
  # cluster-admin via an EKS access entry so kubectl/helm/argocd work from it
  # with only the instance profile (no AWS keys on the box). See jump.tf.
  authentication_mode = "API_AND_CONFIG_MAP"
  access_entries = {
    jump = {
      principal_arn = aws_iam_role.jump.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  eks_managed_node_group_defaults = {
    instance_types = [var.node_instance_type]
    disk_size      = 40
    iam_role_additional_policies = {
      ecr = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  # ONE pool: 2 private nodes run EVERYTHING (frontend + backend + gateway + support).
  eks_managed_node_groups = {
    workers = {
      subnet_ids   = [for s in aws_subnet.private : s.id]
      min_size     = 2
      max_size     = 4
      desired_size = 2
      labels       = { "dokandar.io/node-pool" = "workers" }
    }
  }

  tags = { Name = local.cluster_name }
}

# NodePort range open to VPN clients — standalone rule so Terraform always tracks it.
# ArgoCD UI is :30080; all backend service docs are :300NN. VPN required (nodes are private).
resource "aws_security_group_rule" "worker_nodeports_vpn" {
  security_group_id = module.eks.node_security_group_id
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  # VPN server masquerades client traffic as its own VPC IP, so the nodes see
  # the source as 10.0.1.x — allow the full VPC CIDR (same pattern as jump SG).
  cidr_blocks       = [data.terraform_remote_state.vpn.outputs.vpc_cidr]
  description       = "NodePorts (30000-32767) from VPC (VPN masquerade)"
}

# IRSA for the AWS Load Balancer Controller (INTERNAL ALB for the app ingresses).
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${local.name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
