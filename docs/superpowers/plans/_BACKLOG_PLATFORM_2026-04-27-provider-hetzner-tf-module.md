# Provider — Hetzner Cloud TF Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hetzner Cloud as a third provider parallel to Vultr and Linode. Same module shape, same outputs, same TF mocked test coverage. Closes audit #1 (provider breadth, partial).

**Architecture:** New module `terraform/modules/providers/hetzner/` mirroring the existing vultr/linode pattern: VPC + firewall + N server instances + N client instances + SSH key, with `output "instances"` returning the same normalized shape `{name, role, public_ip, private_ip, provider}`.

**Tech Stack:** `hetznercloud/hcloud` Terraform provider 1.49+, hcloud TF resources.

---

## File Structure

| File | Responsibility |
|---|---|
| `terraform/modules/providers/hetzner/main.tf` | hcloud_network + hcloud_firewall + hcloud_server x N |
| `terraform/modules/providers/hetzner/variables.tf` | mirror vultr/linode signature |
| `terraform/versions.tf` | add hcloud provider |
| `terraform/main.tf` | conditional module instantiation |
| `terraform/tests/cluster.tftest.hcl` | append hetzner mocked tests |
| `terraform/terraform.tfvars.example` | hetzner values |

---

## Task 1: Failing test

```bash
cat >> terraform/tests/cluster.tftest.hcl <<'EOF'

mock_provider "hcloud" {}

run "hetzner_provider_activates_only_hetzner_module" {
  command = plan
  variables { provider_name = "hetzner" }
  assert {
    condition     = length(module.hetzner) == 1
    error_message = "hetzner module must activate when provider_name=hetzner"
  }
  assert {
    condition     = length(module.vultr) == 0 && length(module.linode) == 0
    error_message = "other providers must NOT activate"
  }
}
EOF
cd terraform && tofu test 2>&1 | tail
```

Expected: FAIL because module/provider doesn't exist.

```bash
cd ..
git add terraform/tests/cluster.tftest.hcl
git commit -m "test(hetzner): failing tofu test for module activation"
```

---

## Task 2: Provider + variables

In `terraform/versions.tf` add to required_providers:

```hcl
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
```

Add `provider "hcloud" {}` (reads `HCLOUD_TOKEN` env).

In `terraform/variables.tf` validate `provider_name` includes `hetzner`:

```hcl
variable "provider_name" {
  description = "Cloud provider: vultr|linode|hetzner"
  type        = string
  validation {
    condition     = contains(["vultr", "linode", "hetzner"], var.provider_name)
    error_message = "provider_name must be vultr, linode, or hetzner"
  }
}
```

```bash
git add terraform/versions.tf terraform/variables.tf
git commit -m "feat(terraform): hcloud provider declaration"
```

---

## Task 3: Module

```bash
mkdir -p terraform/modules/providers/hetzner
cat > terraform/modules/providers/hetzner/variables.tf <<'EOF'
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

cat > terraform/modules/providers/hetzner/main.tf <<'EOF'
terraform {
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = "~> 1.49" }
  }
}

resource "hcloud_ssh_key" "cluster" {
  name       = "${var.cluster_name}-key"
  public_key = var.ssh_public_key
}

resource "hcloud_network" "cluster" {
  name     = var.cluster_name
  ip_range = var.vpc_cidr
}

resource "hcloud_network_subnet" "cluster" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.vpc_cidr
}

resource "hcloud_firewall" "cluster" {
  name = "${var.cluster_name}-fw"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

locals {
  server_labels = [for i in range(var.server_count) : "${var.cluster_name}-server-${format("%02d", i + 1)}"]
  client_labels = [for i in range(var.client_count) : "${var.cluster_name}-client-${format("%02d", i + 1)}"]
}

resource "hcloud_server" "servers" {
  count        = var.server_count
  name         = local.server_labels[count.index]
  image        = var.image
  server_type  = var.server_instance_type
  location     = var.region
  ssh_keys     = [hcloud_ssh_key.cluster.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  network {
    network_id = hcloud_network.cluster.id
  }
  labels = { for t in var.cluster_tags : t => "true" }
  depends_on = [hcloud_network_subnet.cluster]
}

resource "hcloud_server" "clients" {
  count        = var.client_count
  name         = local.client_labels[count.index]
  image        = var.image
  server_type  = var.client_instance_type
  location     = var.region
  ssh_keys     = [hcloud_ssh_key.cluster.id]
  firewall_ids = [hcloud_firewall.cluster.id]
  network {
    network_id = hcloud_network.cluster.id
  }
  labels = { for t in var.cluster_tags : t => "true" }
  depends_on = [hcloud_network_subnet.cluster]
}

output "instances" {
  value = concat(
    [
      for s in hcloud_server.servers : {
        name       = s.name
        role       = "server"
        public_ip  = s.ipv4_address
        private_ip = try(s.network[*].ip[0], "")
        provider   = "hetzner"
      }
    ],
    [
      for s in hcloud_server.clients : {
        name       = s.name
        role       = "client"
        public_ip  = s.ipv4_address
        private_ip = try(s.network[*].ip[0], "")
        provider   = "hetzner"
      }
    ]
  )
}
EOF

git add terraform/modules/providers/hetzner/
git commit -m "feat(terraform): hetzner module mirroring vultr/linode shape"
```

---

## Task 4: Wire root + tests

In `terraform/main.tf` add:

```hcl
module "hetzner" {
  source = "./modules/providers/hetzner"
  count  = var.provider_name == "hetzner" ? 1 : 0

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
    var.provider_name == "vultr"   ? module.vultr[0].instances :
    var.provider_name == "linode"  ? module.linode[0].instances :
                                     module.hetzner[0].instances
  )
}
```

(Replace the existing `locals { instances = ... }` block.)

Run tests:

```bash
cd terraform && tofu init -backend=false && tofu validate && tofu test 2>&1 | tail
```

Expected: 5 tests pass (existing 4 + new hetzner one).

```bash
cd ..
git add terraform/main.tf
git commit -m "feat(terraform): wire hetzner module with conditional locals.instances"
```

---

## Task 5: tfvars example + runbook + push

```bash
cat >> terraform/terraform.tfvars.example <<'EOF'

# Hetzner Cloud example
# provider_name = "hetzner"
# region        = "fsn1"
# image         = "ubuntu-24.04"
# server_instance_type = "cax11"   # 2 vCPU ARM, 4GB
# client_instance_type = "cax21"   # 4 vCPU ARM, 8GB
EOF
```

```bash
cat > docs/runbooks/provider-hetzner.md <<'EOF'
# Runbook — Hetzner Cloud Provider

## Setup
1. Create API token: https://console.hetzner.cloud → Project → Security → API Tokens.
2. Export: `export HCLOUD_TOKEN=<token>`.
3. Set `provider_name = "hetzner"` in `terraform.tfvars`.
4. `bin/plan` then `bin/apply`.

## Sizing
- ARM (cax) plans are cheapest per CPU.
- Region `fsn1` (Falkenstein, DE), `nbg1` (Nuremberg, DE), `hel1` (Helsinki), `ash` (Ashburn US), `hil` (Hillsboro US).

## Limitations
- Hetzner storage volumes only attach to servers in the same location.
- IPv6 enabled by default; firewall rules above allow IPv4+IPv6.
EOF
git add terraform/terraform.tfvars.example docs/runbooks/provider-hetzner.md
git commit -m "docs(runbook): hetzner provider"
git push origin main
```

---

## Self-Review

- Audit #1 covered (one more provider).
- No placeholders.
- Type/name consistency: outputs `{name, role, public_ip, private_ip, provider}` identical across providers.
