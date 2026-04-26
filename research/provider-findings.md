# Provider Findings

Saved findings from the official documentation reviewed during setup design.

## Vultr

- Public API v2 is enabled from the account API settings page.
- São Paulo region code is `sao`.
- Public plans endpoint exposes location-specific pricing.
- Official Terraform resources cover instances, firewall groups, VPCs, startup scripts, SSH keys, block storage, object storage, and load balancers.
- Official tooling includes `vultr-cli` and the `govultr` Go SDK.

Official links:

- https://docs.vultr.com/platform/other/api/enable-user-api-access
- https://docs.vultr.com/support/platform/api/what-rate-limits-apply-to-the-vultr-api
- https://docs.vultr.com/reference/terraform/resources
- https://docs.vultr.com/reference/terraform/resources/instance
- https://docs.vultr.com/provision-a-vultr-cloud-server-with-terraform-and-cloud-init
- https://github.com/vultr/vultr-cli
- https://github.com/vultr/govultr

## Akamai/Linode

- Official API and Terraform provider support instance creation and regional pricing.
- São Paulo region code is `br-gru`.
- Official provider docs expose `linode_instance`, `linode_vpc`, `linode_vpc_subnet`, and interface resources.
- Ubuntu 24.04 image slug is `linode/ubuntu24.04`.
- Current design uses the stable instance creation path first, with a module surface ready for VPC and firewall expansion.

Official links:

- https://www.linode.com/pricing/sao-paulo/
- https://techdocs.akamai.com/cloud-computing/docs/create-a-compute-instance
- https://techdocs.akamai.com/linode-api/reference/linode-instances
- https://techdocs.akamai.com/linode-api/reference/rate-limits
- https://registry.terraform.io/providers/linode/linode/latest/docs/resources/instance
- https://registry.terraform.io/providers/linode/linode/latest/docs/resources/vpc
- https://registry.terraform.io/providers/linode/linode/latest/docs/resources/vpc_subnet
- https://registry.terraform.io/providers/linode/linode/latest/docs/resources/interface

## Why Vultr And Linode First

- Both have official Terraform providers and mature APIs.
- Both support São Paulo region pricing and provisioning.
- Both are a better substrate for later autoscaling and platform work than panel-only VPS offerings.

## Why The Bootstrap Uses Terraform + Ansible

- Terraform models provider resources and repeatable cluster shape.
- Ansible handles multi-node bootstrap, re-runs, upgrades, and role-specific service configuration better than cloud-init alone.
- Ingress is deployed as a Nomad job so routing remains part of the scheduler lifecycle instead of becoming a separate machine-level service.
