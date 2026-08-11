# DOKANDAR infra — Master Runbook

| Stage | Folder | Creates |
|-------|--------|---------|
| 1 | `01-vpn-setup/` | VPC + IGW, OpenVPN server, VPN client profiles |
| 2 | `02-platform-setup/` | GitLab runner (public subnet, IAM: ECR push), utilities host (private subnet), NAT, ECR ×20, KMS |
| 3 | `03-eks-setup/` | **Private-only** EKS: 2 worker nodes (all services) + 1 jump server, add-ons (ALB controller, metrics-server, Reloader, ArgoCD), env rendering → jump-server secrets, full deploy |

> Order matters: **01 → VPN up → 02 → 03.** 02/03 read the VPC from 01's
> Terraform state (S3). Private hosts answer only over the VPN; the runner is
> the single public machine (it must poll gitlab.com).

---

## ⚡ Fully automatic — one command, zero manual steps

```bash
cd infra
ansible-playbook site.yml -K          # -K = sudo password once (starts the VPN client)
```

Re-run any single stage (everything is idempotent):

```bash
ansible-playbook site.yml -K --tags vpn
ansible-playbook site.yml -K --tags platform
ansible-playbook site.yml -K --tags eks
```

The manual equivalents below are for learning and debugging.

---

## 0. Prerequisites (control machine, Ubuntu — once)

```bash
# Terraform
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt-get install -y terraform

# AWS CLI v2 + credentials
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install
aws configure                                    # region: ap-southeast-1

# Ansible + OpenVPN client + SSM plugin
sudo apt install -y software-properties-common openvpn
sudo add-apt-repository --yes --update ppa:ansible/ansible && sudo apt install -y ansible
sudo apt-get install -y python3-boto3 python3-botocore
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb && sudo dpkg -i /tmp/smp.deb
ansible-galaxy collection install amazon.aws community.aws

# GitLab PAT (api scope) at the WORKSPACE root — read by Ansible everywhere
printf '%s' "<YOUR_GITLAB_PAT>" > /home/jakir/learningdevopstools/.gitlab_token
chmod 600 /home/jakir/learningdevopstools/.gitlab_token
```

`kubectl` and `helm` are installed automatically by stage 3 if missing.

---

## 1. VPN — `01-vpn-setup`

```bash
cd 01-vpn-setup/terraform
terraform init && terraform validate && terraform apply
# → VPC + IGW + OpenVPN EC2; writes ../<key>.pem + ../ansible/inventory.ini (SSM);
#   exports vpc_id / igw_id / vpc_cidr / vpn_client_cidr for stages 2-3

cd ../ansible
ansible-playbook -i inventory.ini playbook.yml
# → waits for the SSM agent, installs OpenVPN, fetches ../vpn-clients/admin_user.ovpn

sudo openvpn --config ../vpn-clients/admin_user.ovpn --daemon dokandar-vpn
ip link show tun0                                # verify the tunnel is up
```

New VPN users / SSH into the VPN server: `01-vpn-setup/README.md`
(`ansible-playbook create-user.yml -e vpn_user=<name>`, or the manual easy-rsa
procedure over SSH).

---

## 2. Platform — `02-platform-setup` (parallel rollout)

```bash
cd ../../02-platform-setup/terraform
terraform init && terraform validate && terraform apply
# → runner EC2 (public, EIP), utilities EC2 (private), NAT, ECR ×20, KMS;
#   writes ../keys/*.pem + ../ansible/inventory.ini

cd ../ansible
ansible-playbook -i inventory.ini deploy.yml
```

`deploy.yml` runs both hosts **in parallel** (`strategy: free` — no idle servers):

| Utilities host (over the VPN)   | Runner host (public IP)                                  |
|---------------------------------|----------------------------------------------------------|
| Docker + clone utilities repo   | Docker + AWS CLI + gitlab-runner install                 |
| `setup.sh` (16 tools)           | Register group runner (tag `dokandar-runner`)            |
| `setup.sh creds` → `.creds/`    | → trigger all 20 pipelines (build → ECR → manifest bump) |

Partials: `utilities.yml` (VPN required) · `runner.yml` (no VPN needed).

**Runner sizing (automatic):** starts as `c5.2xlarge` (8 vCPU, `concurrent = 10`
— ten images build simultaneously). `site.yml`'s final stage (or manually:
`ansible-playbook downsize-runner.yml` in `02-platform-setup/ansible`) waits
until every pipeline finishes, then shrinks the runner to `t3.small` in place —
the registered runner and Docker survive the resize. Scale back up anytime:
`terraform apply` (defaults restore c5.2xlarge).

### Verify

```bash
cd ../terraform
ssh -i ../keys/dokandar-dev-gitlab-runner.pem ubuntu@$(terraform output -raw runner_public_ip) 'gitlab-runner status; docker ps'
ssh -i ../keys/dokandar-dev-utilities.pem     ubuntu@$(terraform output -raw utilities_private_ip) 'docker ps --format "{{.Names}}"'
# Pipelines: GitLab → group learningdevopstools → CI/CD
```

---

## 3. EKS — `03-eks-setup` (private-only; run after 02's Ansible finishes)

```bash
cd ../../03-eks-setup/terraform
terraform init && terraform validate && terraform apply       # ~15 min
# → EKS (2 private workers, label dokandar.io/node-pool=workers) + jump server;
#   writes ../keys/dokandar-dev-jump-server.pem + ../ansible/eks-vars.yml

cd ../ansible
ansible-playbook setup.yml
# → kubectl/helm bootstrap → 2 Ready nodes → ALB controller (internal) +
#   metrics-server + Reloader + ArgoCD (NodePort 30080) →
#   render envs from the utilities creds → populate jump-server secrets

ansible-playbook setup.yml --tags deploy
# → namespaces → apply-config.sh + apply-secrets.sh → data-collector DaemonSet
#   → all workloads → network policies (then ArgoCD owns manifest-files/)
```

### Access — everything over the VPN

```bash
cd ..
./service-urls.sh                       # every service: http://<node-ip>:300NN (+ /docs)
./argocd-info.sh                        # ArgoCD UI: http://<node-ip>:30080 + admin password
cd terraform && terraform output -raw jump_ssh_command      # SSH to the jump server
```

| Endpoint | URL (VPN connected) |
|----------|---------------------|
| Service `NN` (`/docs`, `/openapi.json`, `/ready`, `/health`, `/data`, `/metrics`) | `http://<node-ip>:300NN` |
| Frontend (shop) | `http://<node-ip>:30020` |
| ArgoCD UI | `http://<node-ip>:30080` |

Day-2 is automatic: `git push` → runner builds → ECR → manifest bump → ArgoCD syncs.
Re-run `setup.yml --tags deploy` only after rotating jump-server config/secrets.

---

## 4. Tear down (ORDER MATTERS: 03 → 02 → 01)

```bash
# STEP 0 — REQUIRED: delete k8s-created load balancers FIRST. The controller's
# ALB/NLB exist in NO terraform state; skipping this fails 01's destroy with
# "VPC has some mapped public address(es)".
kubectl delete ingress -A --all
aws elbv2 describe-load-balancers --region ap-southeast-1 --query 'LoadBalancers[].LoadBalancerName'   # wait until empty

cd 03-eks-setup/terraform  && terraform destroy
cd ../../02-platform-setup/terraform && terraform destroy
cd ../../01-vpn-setup/terraform      && terraform destroy
rm -rf ../vpn-clients ../../02-platform-setup/ansible/.creds ../../03-eks-setup/ansible/.envs
```

KMS keys linger 7 days in `PendingDeletion` (by design). The S3 state bucket
is intentionally never destroyed.

---

## Troubleshooting

- **`TargetNotConnected` right after a terraform apply** — a fresh EC2's SSM
  agent needs 1–3 min; `01`'s `playbook.yml` waits for `PingStatus=Online`
  automatically — just re-run it.
- **`inventory.ini` / `*.pem` missing** — Terraform-managed local files;
  re-run `terraform apply` (no cloud changes, it rewrites them from state).
- **02/03: "Unable to find remote state"** — stage 1 not applied, or its
  backend changed. 01 keeps state in S3 (`backend.tf`); the
  `terraform_remote_state` blocks in 02/03 must mirror the same bucket/key/region.
- **Ansible `UNREACHABLE` on `utilities`** — the VPN is not connected; private
  hosts answer only over the tunnel (`ip link show tun0`).
- **Ran `deploy.yml` with no `inventory.ini`** — only the localhost play runs
  and registers an unused runner token; delete strays under GitLab → group →
  Build → Runners.
- **Pipelines pending forever** — runner tag must be `dokandar-runner` and the
  runner green under GitLab → group → Build → Runners.
- **`update_manifest` job fails** — the group CI variable
  `MANIFEST_PUSH_TOKEN` is missing (site.yml creates it; or add it by hand).
- **Destroy: "VPC has some mapped public address(es)"** — you skipped teardown
  STEP 0; delete the k8s load balancers/target groups, wait for ENIs to
  release, then retry.
