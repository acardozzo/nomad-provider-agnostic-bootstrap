# Provider-Agnostic Nomad Bootstrap Design

**Goal**

Create a fully automated bootstrap for a small Nomad cluster that can provision and configure infrastructure on multiple providers, starting with Vultr and Akamai/Linode.

**Chosen Approach**

Use Terraform for infrastructure provisioning and Ansible for machine bootstrap and cluster configuration.

**Why**

- Terraform is the right layer for graph-based infrastructure creation, provider credentials, and repeatable state.
- Ansible is a better fit than cloud-init alone for multi-node coordination, re-runs, upgrades, and post-provision drift correction.
- A shared output contract keeps the workflow stable across providers.

**Architecture**

- Terraform root module defines shared inputs and dispatches to one provider module at a time.
- Provider modules return a normalized list of instances with role, hostname, public IP, and private IP.
- A helper script renders the Terraform output into an Ansible inventory.
- Ansible installs Docker, Consul, and Nomad, then writes role-specific service configs for server and client nodes.

**Provider Strategy**

- Vultr first-class: VPC, firewall, SSH key, instance creation.
- Linode first-class for instance creation and SSH key, with a clean module surface ready for VPC and firewall extension.
- Future providers can be added by implementing the same output contract as the existing modules.

**Target Cluster**

- `3` Nomad servers
- `2` Nomad clients
- Ubuntu 24.04
- Docker for container tasks
- Consul for service discovery
- Traefik as a Nomad-managed ingress job
- A sample `whoami` service behind Traefik for first-run verification

**Operational Model**

- Provision: `bin/plan` and `bin/apply`
- Inventory render: `bin/render-inventory`
- Bootstrap: `bin/bootstrap`
- Teardown: `bin/destroy`

**User Inputs Required To Finish**

- API token for the chosen provider
- SSH public key
- Region selection
- Optional instance shape overrides
