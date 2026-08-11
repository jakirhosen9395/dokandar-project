# 03-eks-setup — DOKANDAR on Amazon EKS (private-only)

Nothing runs in a public subnet. Three machines total:

| Machine | Where | Purpose |
|---|---|---|
| `workers` ×2 (m7i-flex.xlarge) | private subnets, 2 AZs | ALL services: frontend + backend + api-gateway + support |
| `jump-server` ×1 (t3.small) | private subnet | SSH admin box (holds the jump-server config/secrets flow) |

Egress via 02's NAT; the EKS API endpoint stays public so `kubectl` works
without the VPN, but every node/pod/LB is private.

## The jump server is the sole control host

Kubernetes 1.35. **Nothing is controlled from your laptop.** You still launch
`ansible-playbook` from your machine (VPN connected), but every task runs ON the
jump server over SSH: it installs the tooling (kubectl 1.35, helm, aws-cli,
argocd CLI), clones the backend + manifest repos from GitLab with the PAT, writes
its own kubeconfig via its **instance profile** (no AWS keys on the box — Terraform
grants it cluster-admin through an EKS access entry), installs the add-ons, renders
every service env, and deploys all services as **per-service ArgoCD apps** created
through the `argocd` CLI.

## Deploy

```bash
cd terraform && terraform init && terraform apply       # ~15 min (writes ../ansible/inventory.ini)
cd ../ansible
ansible-playbook -i inventory.ini setup.yml             # bootstrap jump + add-ons + envs + secrets
ansible-playbook -i inventory.ini setup.yml --tags deploy   # create + sync every service's ArgoCD app
```

Prereqs: VPN connected · PAT in `<repo-root>/.gitlab_token` · 02's data-tier creds
present locally (`infra/02-platform-setup/ansible/.creds/infra-creds.txt`).

> **K8s version upgrades:** AWS EKS won't skip minor versions on an existing
> cluster. A fresh cluster is created at 1.35 directly; upgrading an existing
> cluster must step 1.31 → 1.32 → … → 1.35 one `terraform apply` at a time.

## Access (SSH to the jump server, VPN connected)

```bash
cd terraform && terraform output jump_ssh_command   # SSH to the jump server (.pem in ../keys/)
# then, ON the jump server (kubeconfig + kubectl/argocd live there):
argocd app list --core
kubectl get pods -A
```

The `./argocd-info.sh` / `./service-urls.sh` helpers use `kubectl`, so run them on
the jump server (that's where the kubeconfig is) — copy them up or paste the
equivalent one-liners.

- Service NN → `http://<node-ip>:300NN` (`/docs`, `/openapi.json`, `/ready`,
  `/health`, `/data`, `/metrics`) — mirrors the old `100NN` convention.
- Frontend (shop): `http://<node-ip>:30020` · ArgoCD: `:30080`.
- App ingresses (ALB) are `internal` — also VPN-only.

## The `/app/data` + `TENANT=cloud` contract

The `dokandar-data-collector` DaemonSet writes each node's EC2 metadata to
`/opt/dokandar/data/cloud/result.json`; every non-frontend Deployment mounts it
read-only at `/app/data` (k8s equivalent of `-v data:/app/data:ro`).

## Tear down (ORDER MATTERS)

```bash
kubectl delete ingress -A --all        # k8s-created ALBs live in NO tf state
cd terraform && terraform destroy
```
