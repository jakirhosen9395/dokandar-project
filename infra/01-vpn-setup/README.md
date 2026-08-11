# 01-vpn-setup — OpenVPN on AWS (Terraform + Ansible)

Builds and operates the OpenVPN entry point used to reach the private DOKANDAR
hosts. Flattened layout — two directories, nothing else:

```
01-vpn-setup/
├── terraform/        # EC2 + EIP + SG + SSM role; writes <key>.pem to repo root
├── ansible/          # openvpn role, playbook.yml (install), create-user.yml
└── vpn-clients/      # generated: fetched <user>.ovpn profiles (gitignored)
```

> Used by `../02-platform-setup`: its Terraform deploys the OpenVPN EC2 into the
> platform VPC and generates `ansible/inventory.ini` here. Standalone use works
> the same way with this repo's own `terraform/`.

## 1. Deploy

```bash
cd terraform && terraform init && terraform apply     # ~2 min
cd ../ansible && ansible-playbook -i inventory.ini playbook.yml
sudo openvpn --config ../vpn-clients/admin_user.ovpn  # keep running in its own terminal
```

## 2. SSH into the VPN server

Terraform generates a break-glass key at the repo root and prints the exact
command:

```bash
cd terraform && terraform output ssh_command
# → ssh -i /…/01-vpn-setup/<key>.pem ubuntu@<vpn-public-ip>
```

## 3. Create a VPN profile for a new user

### Option A — automated (recommended)

```bash
cd ansible
ansible-playbook create-user.yml -e vpn_user=alice
# → builds the client cert on the server and fetches ../vpn-clients/alice.ovpn
```

Re-running for an existing name re-issues that user's profile. Hand the
`.ovpn` file to the user; they connect with
`sudo openvpn --config alice.ovpn`.

### Option B — manual, over SSH (what the playbook does, by hand)

There is only ONE IP in this whole procedure: the VPN server's public IP.
You SSH to it, and the generated profile tells clients to connect to it.
Get it once, on your machine:

```bash
cd terraform
terraform output -raw vpn_server_public_ip    # e.g. 13.212.99.7 — use this everywhere below
terraform output ssh_command                  # ready-made:  ssh -i <key>.pem ubuntu@<that same IP>
```

```bash
# 1) SSH into the VPN server (the ssh_command above), then become root:
sudo -i

# 2) Issue the client certificate (easy-rsa PKI lives on the server):
cd /etc/openvpn/easy-rsa
EASYRSA_BATCH=1 ./easyrsa build-client-full bob nopass
#   → pki/issued/bob.crt + pki/private/bob.key

# 3) Assemble bob.ovpn — same layout as ansible/roles/openvpn/templates/client.ovpn.j2.
#    PUB_IP = the vpn_server_public_ip from above (the IP you are SSH'd into right now).
#    Shortcut that fills it in automatically on the server:
PUB_IP=$(curl -s https://checkip.amazonaws.com)
cat > /etc/openvpn/server/bob.ovpn <<EOF
client
dev tun
proto udp
remote ${PUB_IP} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
verb 3
<ca>
$(cat pki/ca.crt)
</ca>
<cert>
$(cat pki/issued/bob.crt)
</cert>
<key>
$(cat pki/private/bob.key)
</key>
<tls-crypt>
$(cat /etc/openvpn/server/tls-crypt.key)
</tls-crypt>
EOF
chmod 600 /etc/openvpn/server/bob.ovpn

# 4) Make it downloadable by the ubuntu user, then leave root:
install -m 600 -o ubuntu -g ubuntu /etc/openvpn/server/bob.ovpn /home/ubuntu/bob.ovpn
exit

# 5) From YOUR machine, download the profile (same IP again):
scp -i terraform/<key>.pem ubuntu@$(cd terraform && terraform output -raw vpn_server_public_ip):bob.ovpn vpn-clients/
```

No server restart is needed — new client certs are trusted immediately (they
are signed by the same CA the server already uses). The defaults above
(udp/1194/tun, AES-256-GCM, SHA256, tls-crypt) match
`ansible/roles/openvpn/defaults/main.yml`; if you changed those, mirror your
values.

## 4. Tear down

```bash
cd terraform && terraform destroy
rm -rf ../vpn-clients      # local profiles are useless after destroy
```
