# Provider — DigitalOcean TF Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DigitalOcean as a fourth provider parallel to Vultr/Linode/Hetzner. Same module shape, same outputs, same TF mocked test coverage. Closes audit #1 fully (4 of the 8 orbty providers; AWS/GCP/Azure/Alibaba/Oracle remain explicitly out of scope per ADR 0001 — they're hyperscaler/managed-k8s-friendly providers that conflict with the "non-hyperscaler bootstrap" positioning).

**Architecture:** New module `terraform/modules/providers/digitalocean/` mirroring the existing pattern: VPC + firewall + N droplets per role, normalized output.

**Tech Stack:** `digitalocean/digitalocean` Terraform provider 2.46+.

---

## File Structure

| File | Responsibility |
|---|---|
| `terraform/modules/providers/digitalocean/main.tf` | VPC + firewall + droplets |
| `terraform/modules/providers/digitalocean/variables.tf` | mirror sibling modules |
| `terraform/versions.tf` | add digitalocean provider |
| `terraform/main.tf` | conditional module |
| `terraform/tests/cluster.tftest.hcl` | append DO mocked tests |
| `terraform/terraform.tfvars.example` | DO values |

---

## Task 1: Failing test

```bash
cat >> terraform/tests/cluster.tftest.hcl <<'EOF'

mock_provider "digitalocean" {}

run "do_provider_activates_only_do_module" {
  command = plan
  variables { provider_name = "digitalocean" }
  assert {
    condition     = length(module.digitalocean) == 1
    error_message = "DO module must activate when provider_name=digitalocean"
  }
  assert {
    condition     = length(module.vultr) == 0 && length(module.linode) == 0 && length(module.hetzner) == 0
    error_message = "other providers must NOT activate"
  }
}
EOF

cd terraform && tofu test 2>&1 | tail
cd ..
git add terraform/tests/cluster.tftest.hcl
git commit -m "test(do): failing tofu test for module activation"
```

---

## Task 2: Provider + variable validation

In `terraform/versions.tf` add:

```hcl
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.46"
    }
```

Add `provider "digitalocean" {}` (reads `DIGITALOCEAN_TOKEN` env).

In `terraform/variables.tf` extend the validation:

```hcl
  validation {
    condition     = contains(["vultr", "linode", "hetzner", "digitalocean"], var.provider_name)
    error_message = "provider_name must be vultr, linode, hetzner, or digitalocean"
  }
```

```bash
git add terraform/versions.tf terraform/variables.tf
git commit -m "feat(terraform): digitalocean provider declaration"
```

---

## Task 3: Module

```bash
mkdir -p terraform/modules/providers/digitalocean
cat > terraform/modules/providers/digitalocean/variables.tf <<'EOF'
variable "cluster_name"         { type = string }
variable "region"               { type = string }
variable "server_count"         { type = number }
variable "client_count"         { type = number }
variable "server_instance_type" { type = string }
variable "client_instance_type" { type = string }
variable "image"                { type = string }
variable "ssh_public_key"       { type = string }
variable "vpc_cidr"             { type = string }
variable "cluster_tags"         { type = list(string) }
EOF

cat > terraform/modules/providers/digitalocean/main.tf <<'EOF'
terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.46" }
  }
}

resource "digitalocean_ssh_key" "cluster" {
  name       = "${var.cluster_name}-key"
  public_key = var.ssh_public_key
}

resource "digitalocean_vpc" "cluster" {
  name     = var.cluster_name
  region   = var.region
  ip_range = var.vpc_cidr
}

resource "digitalocean_firewall" "cluster" {
  name = "${var.cluster_name}-fw"

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  droplet_ids = concat(digitalocean_droplet.servers[*].id, digitalocean_droplet.clients[*].id)
}

locals {
  server_labels = [for i in range(var.server_count) : "${var.cluster_name}-server-${format("%02d", i + 1)}"]
  client_labels = [for i in range(var.client_count) : "${var.cluster_name}-client-${format("%02d", i + 1)}"]
}

resource "digitalocean_droplet" "servers" {
  count    = var.server_count
  name     = local.server_labels[count.index]
  image    = var.image
  size     = var.server_instance_type
  region   = var.region
  vpc_uuid = digitalocean_vpc.cluster.id
  ssh_keys = [digitalocean_ssh_key.cluster.id]
  tags     = concat(var.cluster_tags, ["server"])
}

resource "digitalocean_droplet" "clients" {
  count    = var.client_count
  name     = local.client_labels[count.index]
  image    = var.image
  size     = var.client_instance_type
  region   = var.region
  vpc_uuid = digitalocean_vpc.cluster.id
  ssh_keys = [digitalocean_ssh_key.cluster.id]
  tags     = concat(var.cluster_tags, ["client"])
}

output "instances" {
  value = concat(
    [
      for d in digitalocean_droplet.servers : {
        name       = d.name
        role       = "server"
        public_ip  = d.ipv4_address
        private_ip = d.ipv4_address_private
        provider   = "digitalocean"
      }
    ],
    [
      for d in digitalocean_droplet.clients : {
        name       = d.name
        role       = "client"
        public_ip  = d.ipv4_address
        private_ip = d.ipv4_address_private
        provider   = "digitalocean"
      }
    ]
  )
}
EOF

git add terraform/modules/providers/digitalocean/
git commit -m "feat(terraform): digitalocean module"
```

---

## Task 4: Wire into root + tests

Update `terraform/main.tf`:

```hcl
module "digitalocean" {
  source = "./modules/providers/digitalocean"
  count  = var.provider_name == "digitalocean" ? 1 : 0

  cluster_name         = var.cluster_name
  region               = var.region
  server_count         = var.server_count
  client_count         = var.client_count
  server_instance_type = var.server_instance_type
  client_instance_type = var.client_instance_type
  image                = var.image
  ssh_public_key       = var.ssh_public_key
  vpc_cidr             = var.vpc_cidr
  cluster_tags         = local.cluster_tags
}

locals {
  instances = (
    var.provider_name == "vultr"        ? module.vultr[0].instances        :
    var.provider_name == "linode"       ? module.linode[0].instances       :
    var.provider_name == "hetzner"      ? module.hetzner[0].instances      :
                                          module.digitalocean[0].instances
  )
}
```

Run tests:

```bash
cd terraform && tofu init -backend=false && tofu validate && tofu test 2>&1 | tail
cd ..
git add terraform/main.tf
git commit -m "feat(terraform): wire digitalocean module"
```

---

## Task 5: tfvars + runbook + push

```bash
cat >> terraform/terraform.tfvars.example <<'EOF'

# DigitalOcean example
# provider_name = "digitalocean"
# region        = "nyc3"
# image         = "ubuntu-24-04-x64"
# server_instance_type = "s-2vcpu-2gb"
# client_instance_type = "s-2vcpu-4gb"
EOF

cat > docs/runbooks/provider-digitalocean.md <<'EOF'
# Runbook — DigitalOcean Provider

## Setup
1. API token: https://cloud.digitalocean.com/account/api/tokens (read+write).
2. `export DIGITALOCEAN_TOKEN=<token>`.
3. Set `provider_name = "digitalocean"` in `terraform.tfvars`.
4. `bin/plan && bin/apply`.

## Sizing
- s-2vcpu-2gb ($18/mo) for servers.
- s-2vcpu-4gb ($24/mo) for clients (more memory headroom).
- Switch to `s-1vcpu-1gb` ($6/mo) for dev/local-replica.

## Region selection
- `nyc1/nyc3` East US, `sfo3` West, `lon1` Europe, `sgp1` Singapore.
EOF
git add terraform/terraform.tfvars.example docs/runbooks/provider-digitalocean.md
git commit -m "docs(runbook): digitalocean provider"
git push origin main
```

---

## Self-Review

- Audit #1 closed for the 4 providers in scope (Vultr, Linode, Hetzner, DO). AWS/GCP/Azure/Alibaba/Oracle deferred per ADR 0001.
- No placeholders.
- Type/name consistency: provider sub-module outputs identical across all 4.
