# Nomad Provider-Agnostic Bootstrap

Provider-agnostic infrastructure and configuration automation for a small Nomad cluster, starting with Vultr and Akamai/Linode.

This repository provisions:

- `3` control-plane nodes
- `2` workload nodes
- Ubuntu 24.04 instances
- Docker, Consul, and Nomad
- Traefik deployed as a Nomad-managed ingress job
- A sample `whoami` app routed through Traefik at `/whoami`
- Shared Terraform outputs that feed a generated Ansible inventory

The first supported providers are:

- `vultr`
- `linode`

The project is intentionally split into a shared core plus provider-specific Terraform modules so we can extend it without rewriting the bootstrap flow.

## Layout

- `docs/` design docs, plan docs, and runbooks
- `research/` saved provider findings and official links
- `terraform/` shared stack and provider modules
- `ansible/` machine bootstrap and service configuration
- `bin/` helper scripts for plan, apply, bootstrap, and destroy

## What Works Today

- Provider selection with a shared variable contract
- Vultr cluster provisioning with VPC, firewall, SSH key, and instances
- Linode cluster provisioning with SSH key and instances, ready for firewall and VPC expansion
- Inventory generation from Terraform outputs
- Ansible installation and configuration for Docker, Consul, Nomad, Traefik, and a sample app

## What You Need To Provide

- A provider API token:
  - `VULTR_API_KEY` for Vultr
  - `LINODE_TOKEN` for Akamai/Linode
- An SSH public key
- Your preferred region per provider

## Quick Start

1. Copy the sample variables:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Edit `terraform/terraform.tfvars` and set:

```hcl
provider_name        = "vultr"
cluster_name         = "nomad-sp"
region               = "sao"
ssh_public_key       = "ssh-ed25519 AAAA..."
ansible_user         = "root"
server_instance_type = "vc2-1c-1gb"
client_instance_type = "vc2-1c-2gb"
image                = "Ubuntu 24.04 LTS x64"
```

3. Export the provider token:

```bash
export VULTR_API_KEY="..."
```

or

```bash
export LINODE_TOKEN="..."
```

For Linode, use provider-specific values in `terraform.tfvars`:

```hcl
provider_name        = "linode"
region               = "br-gru"
server_instance_type = "g6-nanode-1"
client_instance_type = "g6-standard-1"
image                = "linode/ubuntu24.04"
```

4. Run the full flow:

```bash
bin/apply
bin/bootstrap
```

After bootstrap, Traefik is submitted to Nomad from the first server node and binds:

- `80/tcp`
- `443/tcp`
- `8080/tcp` for the Traefik dashboard API

The bootstrap also submits a sample `whoami` service. Once DNS or public IP access is available, test it with:

```bash
curl http://<public-ip>/whoami
```

## DNS prerequisites for TLS

Before `bin/bootstrap`, point an A record for `traefik_domain` and
`traefik_dashboard_host` (set in `ansible/group_vars/all.yml`) at any client
node's public IP. Traefik solves Let's Encrypt HTTP-01 on port 80, so the
target host must be publicly reachable on port 80 during issuance.

The dashboard basic-auth hash is generated locally by `secrets.yml`, which
requires the `htpasswd` binary (`apache2-utils` on Debian/Ubuntu,
`httpd-tools` on RHEL, `httpd` on macOS via brew).

## Notes

- Vultr setup is richer today because its VPC and firewall resources are straightforward in the official provider docs.
- Linode setup is kept intentionally clean and minimal for the first pass so we can extend it safely with VPC and firewall attachment once we pin the exact resource behavior you want.
- Traefik is managed by Nomad rather than systemd so ingress stays inside the scheduler workflow.
- This repo assumes `terraform`, `ansible`, and `jq` are installed locally.
