# Provider-Agnostic Nomad Bootstrap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a provider-agnostic Terraform and Ansible project that provisions and bootstraps a five-node Nomad cluster on Vultr or Akamai/Linode.

**Architecture:** Terraform owns infra state and returns normalized instance metadata. Ansible uses that metadata to install Docker, Consul, and Nomad, then configures server and client nodes with a shared inventory flow.

**Tech Stack:** Terraform, Ansible, shell scripts, Vultr provider, Linode provider

---

### Task 1: Write project docs and research snapshot

**Files:**
- Create: `README.md`
- Create: `docs/plans/2026-04-25-provider-agnostic-nomad-bootstrap-design.md`
- Create: `research/provider-findings.md`

**Step 1: Write the docs**

Document the repository layout, supported providers, operator workflow, and official provider findings.

**Step 2: Verify the files exist**

Run: `find . -maxdepth 2 -type f | sort`
Expected: the docs and research files are listed.

### Task 2: Build the shared Terraform contract

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/main.tf`
- Create: `terraform/outputs.tf`
- Create: `terraform/terraform.tfvars.example`

**Step 1: Define shared variables**

Add provider name, region, cluster shape, SSH key, image, and instance type variables.

**Step 2: Add provider dispatch**

Call only the selected provider module and normalize its outputs.

**Step 3: Verify formatting and validation**

Run: `terraform -chdir=terraform fmt -check`
Expected: no formatting errors.

### Task 3: Add provider modules

**Files:**
- Create: `terraform/modules/providers/vultr/main.tf`
- Create: `terraform/modules/providers/vultr/variables.tf`
- Create: `terraform/modules/providers/linode/main.tf`
- Create: `terraform/modules/providers/linode/variables.tf`

**Step 1: Add Vultr resources**

Provision SSH key, VPC, firewall, and instances.

**Step 2: Add Linode resources**

Provision SSH key and instances with a module surface that stays compatible with the shared root contract.

**Step 3: Verify Terraform syntax**

Run: `terraform -chdir=terraform init -backend=false`
Expected: providers install and configuration loads.

### Task 4: Add Ansible automation

**Files:**
- Create: `ansible/ansible.cfg`
- Create: `ansible/group_vars/all.yml`
- Create: `ansible/playbooks/bootstrap.yml`
- Create: `ansible/roles/common/tasks/main.yml`
- Create: `ansible/roles/consul/tasks/main.yml`
- Create: `ansible/roles/consul/templates/consul.hcl.j2`
- Create: `ansible/roles/consul/templates/consul.service.j2`
- Create: `ansible/roles/nomad/tasks/main.yml`
- Create: `ansible/roles/nomad/templates/nomad-server.hcl.j2`
- Create: `ansible/roles/nomad/templates/nomad-client.hcl.j2`
- Create: `ansible/roles/nomad/templates/nomad.service.j2`

**Step 1: Install prerequisites**

Install Docker, curl, unzip, and service dependencies.

**Step 2: Install Consul and Nomad**

Download release zips and install binaries plus systemd units.

**Step 3: Render cluster config**

Template server and client configs from inventory groups and host vars.

### Task 5: Add operator scripts

**Files:**
- Create: `bin/plan`
- Create: `bin/apply`
- Create: `bin/render-inventory`
- Create: `bin/bootstrap`
- Create: `bin/destroy`
- Create: `.gitignore`

**Step 1: Add helper scripts**

Wrap Terraform and Ansible commands into a consistent operator flow.

**Step 2: Verify executability**

Run: `find bin -type f -maxdepth 1 -exec test -x {} \; -print`
Expected: every file in `bin/` is executable.

### Task 6: Verify the scaffold

**Files:**
- Verify all files above

**Step 1: Run basic checks**

Run: `terraform -chdir=terraform fmt -check`
Expected: PASS

Run: `ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/bootstrap.yml --syntax-check`
Expected: PASS

**Step 2: Summarize required secrets**

List the remaining credentials and values the operator must supply before apply/bootstrap.

### Task 7: Add ingress verification app

**Files:**
- Modify: `ansible/playbooks/bootstrap.yml`
- Create: `ansible/roles/sample_app/tasks/main.yml`
- Create: `ansible/roles/sample_app/templates/whoami.nomad.hcl.j2`
- Test: `tests/smoke/test_ingress_assets.sh`

**Step 1: Write the failing smoke test**

Assert that the sample app role exists, bootstrap includes it, and the Nomad job includes Traefik routing tags.

**Step 2: Run the smoke test to verify it fails**

Run: `tests/smoke/test_ingress_assets.sh`
Expected: FAIL because sample app assets are missing.

**Step 3: Add the sample app**

Submit a Nomad-managed `whoami` service with Traefik tags and a path-based route.

**Step 4: Re-run the smoke test**

Run: `tests/smoke/test_ingress_assets.sh`
Expected: PASS
