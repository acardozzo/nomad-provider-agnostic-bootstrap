# DNS Automation (Cloudflare Terraform Provider) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `cloudflare/cloudflare` Terraform provider and a small DNS module that creates A records for the cluster's traefik domain and per-app subdomains, reading client public IPs from `terraform output instances`. Closes the manual A-record gap (audit #4).

**Architecture:** New module `terraform/modules/dns/cloudflare/` accepts `zone_id` and a `records` list of `{name, value, proxied}`. Root `terraform/main.tf` instantiates it with `for_each` over a list of records derived from `local.instances`. Existing Cloudflare token (in `secrets.yml`) is reused via TF env `CLOUDFLARE_API_TOKEN`.

**Tech Stack:** Terraform/OpenTofu, `cloudflare/cloudflare` provider 4.x.

---

## File Structure

| File | Responsibility |
|---|---|
| `terraform/modules/dns/cloudflare/main.tf` | provider passthrough + record resource |
| `terraform/modules/dns/cloudflare/variables.tf` | zone_id, records list |
| `terraform/modules/dns/cloudflare/outputs.tf` | record IDs |
| `terraform/main.tf` | instantiate module |
| `terraform/variables.tf` | add `cloudflare_zone_id`, `dns_records` map |
| `terraform/versions.tf` | add cloudflare provider |
| `terraform/tests/cluster.tftest.hcl` | extend mocked tests to cover module activation |
| `bin/render-inventory` | optional: read DNS records into a status print |

---

## Task 1: Failing test in tofu test

```bash
cd /Users/ailtoncardozo/src/nomad-provider-agnostic-bootstrap

# Append a new run block to existing tftest
cat >> terraform/tests/cluster.tftest.hcl <<'EOF'

mock_provider "cloudflare" {}

run "dns_records_render_when_zone_set" {
  command = plan

  variables {
    provider_name        = "vultr"
    cloudflare_zone_id   = "stub-zone"
    dns_records = {
      "traefik" = { name = "traefik", value = "1.2.3.4", proxied = false }
    }
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "dns module must activate when cloudflare_zone_id set"
  }
}

run "dns_module_skipped_without_zone" {
  command = plan

  variables {
    provider_name      = "vultr"
    cloudflare_zone_id = ""
  }

  assert {
    condition     = length(module.dns) == 0
    error_message = "dns module must NOT activate without zone"
  }
}
EOF

cd terraform && tofu test 2>&1 | tail
```

Expected: FAIL because module doesn't exist, variable doesn't exist.

```bash
cd ..
git add terraform/tests/cluster.tftest.hcl
git commit -m "test(dns): failing tofu test for cloudflare module activation"
```

---

## Task 2: Variables

```bash
cat >> terraform/variables.tf <<'EOF'

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID (orbty.app etc.). Empty disables DNS automation."
  type        = string
  default     = ""
}

variable "dns_records" {
  description = "Map of DNS records to create in the Cloudflare zone."
  type = map(object({
    name    = string
    value   = string
    proxied = bool
  }))
  default = {}
}
EOF
```

---

## Task 3: Provider

```bash
cat > /tmp/versions-patch.tf <<'EOF'
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
EOF
```

Open `terraform/versions.tf` and inside `required_providers { ... }` add the block above. Then add provider config:

```hcl
provider "cloudflare" {}
```

(The provider reads `CLOUDFLARE_API_TOKEN` from env; no inline secret.)

---

## Task 4: Module

```bash
mkdir -p terraform/modules/dns/cloudflare

cat > terraform/modules/dns/cloudflare/variables.tf <<'EOF'
variable "zone_id" { type = string }
variable "records" {
  type = map(object({
    name    = string
    value   = string
    proxied = bool
  }))
}
EOF

cat > terraform/modules/dns/cloudflare/main.tf <<'EOF'
terraform {
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.40" }
  }
}

resource "cloudflare_record" "this" {
  for_each = var.records

  zone_id = var.zone_id
  name    = each.value.name
  type    = "A"
  value   = each.value.value
  proxied = each.value.proxied
  ttl     = each.value.proxied ? 1 : 300
  comment = "managed by orbty terraform"
}
EOF

cat > terraform/modules/dns/cloudflare/outputs.tf <<'EOF'
output "record_ids" {
  value = { for k, v in cloudflare_record.this : k => v.id }
}
EOF
```

---

## Task 5: Wire into root

Add to `terraform/main.tf`:

```hcl
module "dns" {
  source = "./modules/dns/cloudflare"
  count  = var.cloudflare_zone_id != "" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  records = var.dns_records
}
```

Validate:

```bash
cd terraform && tofu init -backend=false && tofu validate && tofu test 2>&1 | tail
```

Expected: tests pass.

```bash
cd ..
git add terraform/
git commit -m "feat(terraform): cloudflare dns module + tests"
```

---

## Task 6: Wire records into apply flow

The records you usually want:

| name | value | proxied |
|---|---|---|
| `@` (apex) | `<client public IP>` | false |
| `www` | `<client public IP>` | true |
| `traefik` | `<client public IP>` | false |
| each app subdomain | `<client public IP>` | false |

In `terraform.tfvars` (or via env / -var-file):

```hcl
cloudflare_zone_id = "61202681345542b89036a0d7aad89218"

dns_records = {
  "apex"    = { name = "@",       value = "192.0.2.10", proxied = false }
  "www"     = { name = "www",     value = "192.0.2.10", proxied = true  }
  "traefik" = { name = "traefik", value = "192.0.2.10", proxied = false }
}
```

Optionally compute `value` from `local.instances` outputs once that data flows (a generator script in `bin/render-dns-records` is one approach).

```bash
git add terraform/terraform.tfvars.example
git commit -m "docs(terraform): example dns_records var"
```

---

## Task 7: Smoke

```bash
cat > tests/smoke/test_dns_records.sh <<'EOF'
#!/usr/bin/env bash
# After tofu apply, verify the records resolve correctly.
set -euo pipefail
ZONE="${1:-orbty.app}"
EXPECT_IP="${2:-}"

for sub in @ www traefik; do
  host="$([[ $sub == @ ]] && echo "$ZONE" || echo "$sub.$ZONE")"
  ip=$(dig +short A "$host" @1.1.1.1 | head -1)
  echo "=== $host -> $ip ==="
  if [[ -n "$EXPECT_IP" && "$ip" != "$EXPECT_IP" ]]; then
    echo "FAIL: expected $EXPECT_IP, got $ip"
    exit 1
  fi
done
echo "ALL DNS RECORD CHECKS PASSED"
EOF
chmod +x tests/smoke/test_dns_records.sh

git add tests/smoke/test_dns_records.sh
git commit -m "test(dns): post-apply DNS smoke"
git push origin main
```

---

## Task 8: Runbook

```bash
cat > docs/runbooks/dns.md <<'EOF'
# Runbook — DNS Automation

## How records are managed
- Cloudflare zone managed by Terraform module `terraform/modules/dns/cloudflare`.
- Records configured in `terraform.tfvars` under `dns_records`.
- Provider auth via `CLOUDFLARE_API_TOKEN` env var (sourced from `secrets.yml`).

## Adding a new record
1. Edit `terraform.tfvars` and add to `dns_records`:
   ```hcl
   "myapp" = { name = "myapp", value = "<ip>", proxied = false }
   ```
2. `bin/plan` (or `tofu plan`) — review.
3. `bin/apply` — Cloudflare API call creates the A record.
4. `bash tests/smoke/test_dns_records.sh orbty.app <ip>` — verify.

## Switching from manual to TF-managed
1. `tofu import 'module.dns[0].cloudflare_record.this["traefik"]' <zone_id>/<record_id>`
2. Repeat for each existing record.
3. Future changes go through the standard plan/apply.

## Token rotation
1. Generate new token in Cloudflare dashboard.
2. Update `secrets.yml` and re-source.
3. Old token can be revoked after first successful `tofu apply` with the new one.
EOF
git add docs/runbooks/dns.md
git commit -m "docs(runbook): dns automation"
git push origin main
```

---

## Self-Review

- Audit #4 covered.
- No placeholders.
- Type/name consistency: `cloudflare_zone_id`, `dns_records` aligned across variables.tf, tests, module.
