# 02-platform-setup — Runner (public) + Utilities (private)

Terraform consumes the VPC from `../01-vpn-setup` (terraform_remote_state) and
creates: public subnet → **gitlab-runner** EC2 (EIP, IAM: ECR push), private
subnet → **utilities** EC2 (NAT egress, SSM, reachable over the VPN), ECR ×20,
KMS. Ansible then provisions **both hosts in parallel** and triggers all
pipelines from your machine using the GitLab PAT.

## 0. Prerequisites

- `../01-vpn-setup` applied (VPC + VPN live), VPN client connected.
- GitLab PAT (api scope) in the workspace root: `<repo-root>/.gitlab_token`.

## 1. Terraform

```bash
cd terraform
terraform init && terraform validate && terraform apply
# → ../keys/*.pem, ../ansible/inventory.ini (runner=public IP, utilities=private IP)
```

## 2. Ansible — everything, in parallel

```bash
cd ../ansible
ansible-playbook -i inventory.ini deploy.yml
```

What happens (strategy: free — no host waits for the other):

| Utilities host (over VPN)         | Runner host (public IP)                          |
|-----------------------------------|--------------------------------------------------|
| Docker + clone utilities repo     | Docker + AWS CLI + gitlab-runner install         |
| `setup.sh` (16 tools, ~minutes)   | Register runner (tag `dokandar-runner`)          |
| `setup.sh creds` → `.creds/`      | → trigger all 20 pipelines (build → ECR → manifest bump) |

Then, automatically (Play 3, `downsize-runner.yml` imported at the end of
`deploy.yml`): the control node **waits 20 min** to let the build wave run on the
big runner, then shrinks it in-place from `c5.2xlarge` to **`m7i-flex.large`**
(the registered runner + Docker survive the stop/resize/start). Override the wait
with `-e downsize_wait_minutes=30` or the target size with
`-e runner_steady_type=t3.small`. Scale the runner back up anytime with a plain
`terraform apply` (defaults restore `c5.2xlarge`).

Partials: `utilities.yml` (data tier only, needs VPN) ·
`runner.yml` (runner + pipeline trigger only, works without VPN) ·
`downsize-runner.yml` (the 20-min-wait + shrink step, standalone).

## 3. Verify

```bash
ssh -i ../keys/dokandar-dev-gitlab-runner.pem ubuntu@$(cd terraform && terraform output -raw runner_public_ip) 'gitlab-runner status; docker ps'
# utilities (VPN connected):
ssh -i ../keys/dokandar-dev-utilities.pem ubuntu@$(cd terraform && terraform output -raw utilities_private_ip) 'docker ps --format "{{.Names}}"'
# pipelines: GitLab → group learningdevopstools → CI/CD
```

## 4. Tear down

```bash
cd terraform && terraform destroy        # platform only; the VPC/VPN survive (owned by 01)
```
