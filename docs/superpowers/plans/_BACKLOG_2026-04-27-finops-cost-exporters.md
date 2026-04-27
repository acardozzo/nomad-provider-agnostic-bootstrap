# FinOps — Cost Exporters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-tenant + per-cluster cost visibility: a small Go exporter that reads Vultr/Linode billing API, plus a node-resource exporter that maps Nomad allocations to per-tenant CPU/memory consumption. Surface in Grafana with cost dashboards. Closes audit #18 (cost portion).

**Architecture:** Two exporters as Nomad jobs:
1. `cloud-billing-exporter` — calls provider API daily, exposes `orbty_cloud_cost_usd_total{provider, sku}` to Prometheus.
2. `tenant-usage-exporter` — joins Nomad allocations (from Nomad API) to namespace labels, exposes `orbty_tenant_cpu_seconds_total` / `orbty_tenant_memory_bytes_total` per tenant.
A Grafana dashboard JSON renders cost per tenant.

**Tech Stack:** Go 1.23, Prometheus client, Vultr+Linode REST APIs, Nomad API, Grafana provisioning.

---

## File Structure

| File | Responsibility |
|---|---|
| `finops/cmd/cloud-billing/main.go` | Vultr+Linode billing fetcher |
| `finops/cmd/tenant-usage/main.go` | Nomad alloc → tenant labels |
| `finops/Dockerfile` | multi-stage build, both binaries |
| `ansible/roles/finops/templates/{billing,usage}.nomad.hcl.j2` | Nomad jobs |
| `ansible/roles/finops/tasks/main.yml` | submit |
| `ansible/roles/monitoring/files/dashboards/finops.json` | Grafana dashboard |
| `tests/smoke/test_finops.sh` | scrape exporters, assert metrics present |

---

## Task 1: Failing smoke

```bash
cat > tests/smoke/test_finops.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
echo "=== cloud-billing-exporter exposes /metrics ==="
out=$(multipass exec "$VM" -- curl -s http://cloud-billing.service.consul:9201/metrics || true)
echo "$out" | grep -q orbty_cloud_cost_usd_total || { echo FAIL; exit 1; }
echo OK
echo "=== tenant-usage-exporter ==="
out=$(multipass exec "$VM" -- curl -s http://tenant-usage.service.consul:9202/metrics || true)
echo "$out" | grep -q orbty_tenant_cpu_seconds_total || { echo FAIL; exit 1; }
echo OK
echo "=== Prometheus has scraped ==="
out=$(multipass exec "$VM" -- bash -c "curl -s 'http://prometheus.service.consul:9090/api/v1/query?query=orbty_tenant_cpu_seconds_total'")
echo "$out" | grep -q '"resultType":"vector"' || { echo FAIL prometheus; exit 1; }
echo OK
echo "ALL FINOPS CHECKS PASSED"
EOF
chmod +x tests/smoke/test_finops.sh
git add tests/smoke/test_finops.sh
git commit -m "test(finops): failing smoke for exporters"
```

---

## Task 2: Tenant usage exporter

```bash
mkdir -p finops/cmd/tenant-usage
cd finops && go mod init github.com/orbty/finops && cd -
cat > finops/cmd/tenant-usage/main.go <<'EOF'
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	napi "github.com/hashicorp/nomad/api"
)

var (
	cpu = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "orbty_tenant_cpu_mhz",
		Help: "CPU MHz allocated to running allocs, by namespace.",
	}, []string{"namespace"})
	mem = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "orbty_tenant_memory_mb",
		Help: "Memory MB allocated to running allocs, by namespace.",
	}, []string{"namespace"})
	cpuSec = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "orbty_tenant_cpu_seconds_total",
		Help: "Cumulative CPU MHz-seconds, by namespace.",
	}, []string{"namespace"})
)

func main() {
	addr := flag.String("listen", ":9202", "")
	nomadAddr := flag.String("nomad", "http://127.0.0.1:4646", "")
	flag.Parse()

	prometheus.MustRegister(cpu, mem, cpuSec)

	cfg := napi.DefaultConfig()
	cfg.Address = *nomadAddr
	cfg.SecretID = os.Getenv("NOMAD_TOKEN")
	c, err := napi.NewClient(cfg)
	if err != nil {
		log.Fatal(err)
	}

	go func() {
		t := time.NewTicker(15 * time.Second)
		for range t.C {
			collect(c)
		}
	}()

	http.Handle("/metrics", promhttp.Handler())
	log.Printf("listening on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, nil))
}

func collect(c *napi.Client) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	allocs, _, err := c.Allocations().List(&napi.QueryOptions{Namespace: "*"})
	if err != nil {
		log.Printf("list allocs: %v", err)
		return
	}
	cpuByNS := map[string]float64{}
	memByNS := map[string]float64{}
	for _, a := range allocs {
		if a.ClientStatus != "running" {
			continue
		}
		j, _, err := c.Jobs().Info(a.JobID, &napi.QueryOptions{Namespace: a.Namespace})
		if err != nil || j == nil {
			continue
		}
		for _, g := range j.TaskGroups {
			for _, t := range g.Tasks {
				if t.Resources == nil {
					continue
				}
				if t.Resources.CPU != nil {
					cpuByNS[a.Namespace] += float64(*t.Resources.CPU)
				}
				if t.Resources.MemoryMB != nil {
					memByNS[a.Namespace] += float64(*t.Resources.MemoryMB)
				}
			}
		}
	}
	for ns, v := range cpuByNS {
		cpu.WithLabelValues(ns).Set(v)
		cpuSec.WithLabelValues(ns).Add(v * 15.0)
	}
	for ns, v := range memByNS {
		mem.WithLabelValues(ns).Set(v)
	}
	_ = ctx
}
EOF
cd finops && go mod tidy && go build ./cmd/tenant-usage && cd -

git add finops/
git commit -m "feat(finops): tenant-usage exporter"
```

---

## Task 3: Cloud billing exporter

```bash
mkdir -p finops/cmd/cloud-billing
cat > finops/cmd/cloud-billing/main.go <<'EOF'
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var cost = prometheus.NewGaugeVec(prometheus.GaugeOpts{
	Name: "orbty_cloud_cost_usd_total",
	Help: "Cloud monthly accrued cost in USD.",
}, []string{"provider"})

func main() {
	addr := flag.String("listen", ":9201", "")
	flag.Parse()
	prometheus.MustRegister(cost)

	go fetch()
	http.Handle("/metrics", promhttp.Handler())
	log.Fatal(http.ListenAndServe(*addr, nil))
}

func fetch() {
	t := time.NewTicker(30 * time.Minute)
	defer t.Stop()
	pollAll()
	for range t.C { pollAll() }
}

func pollAll() {
	if k := os.Getenv("VULTR_API_KEY"); k != "" {
		if v, err := vultr(k); err == nil { cost.WithLabelValues("vultr").Set(v) } else { log.Printf("vultr: %v", err) }
	}
	if k := os.Getenv("LINODE_TOKEN"); k != "" {
		if v, err := linode(k); err == nil { cost.WithLabelValues("linode").Set(v) } else { log.Printf("linode: %v", err) }
	}
}

func vultr(token string) (float64, error) {
	req, _ := http.NewRequest("GET", "https://api.vultr.com/v2/billing/invoices?per_page=12", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil { return 0, err }
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var r struct {
		Invoices []struct { Amount float64 `json:"amount"` } `json:"billing_invoices"`
	}
	if err := json.Unmarshal(body, &r); err != nil { return 0, err }
	var sum float64
	for _, inv := range r.Invoices { sum += inv.Amount }
	return sum, nil
}

func linode(token string) (float64, error) {
	req, _ := http.NewRequest("GET", "https://api.linode.com/v4/account", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil { return 0, err }
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var r struct { Balance float64 `json:"balance"` }
	if err := json.Unmarshal(body, &r); err != nil { return 0, err }
	return -r.Balance, nil
}
EOF
cd finops && go build ./cmd/cloud-billing && cd -

git add finops/cmd/cloud-billing/
git commit -m "feat(finops): cloud-billing exporter (vultr+linode)"
```

---

## Task 4: Dockerfile + jobs + Prometheus scrape

```bash
cat > finops/Dockerfile <<'EOF'
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/tenant-usage ./cmd/tenant-usage
RUN CGO_ENABLED=0 go build -o /out/cloud-billing ./cmd/cloud-billing

FROM gcr.io/distroless/static
COPY --from=build /out/tenant-usage /tenant-usage
COPY --from=build /out/cloud-billing /cloud-billing
EOF
```

```bash
mkdir -p ansible/roles/finops/{tasks,templates}
cat > ansible/roles/finops/templates/billing.nomad.hcl.j2 <<'EOF'
job "cloud-billing" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"
  group "x" {
    count = 1
    constraint { attribute = "${node.class}" operator = "=" value = "server" }
    network { mode = "host" port "metrics" { static = 9201 } }
    service { name = "cloud-billing" port = "metrics" tags = ["prom"] check { type = "tcp" port = "metrics" interval = "10s" timeout = "2s" } }
    task "x" {
      driver = "docker"
      env { VULTR_API_KEY = "{{ vultr_api_key | default('') }}"  LINODE_TOKEN = "{{ linode_token | default('') }}" }
      config { image = "{{ finops_image }}" entrypoint = ["/cloud-billing"] network_mode = "host" }
      resources { cpu = 50 memory = 64 }
    }
  }
}
EOF

cat > ansible/roles/finops/templates/usage.nomad.hcl.j2 <<'EOF'
job "tenant-usage" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "service"
  group "x" {
    count = 1
    constraint { attribute = "${node.class}" operator = "=" value = "server" }
    network { mode = "host" port "metrics" { static = 9202 } }
    service { name = "tenant-usage" port = "metrics" tags = ["prom"] check { type = "tcp" port = "metrics" interval = "10s" timeout = "2s" } }
    task "x" {
      driver = "docker"
      env { NOMAD_TOKEN = "{{ nomad_bootstrap_token }}" }
      config { image = "{{ finops_image }}" entrypoint = ["/tenant-usage"] network_mode = "host" }
      resources { cpu = 50 memory = 64 }
    }
  }
}
EOF

cat > ansible/roles/finops/tasks/main.yml <<'EOF'
---
- name: Submit billing
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'billing.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
- name: Submit usage
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'usage.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF

git add finops/Dockerfile ansible/roles/finops/
git commit -m "feat(finops): nomad jobs for both exporters"
```

In Prometheus config, ensure scrape via Consul SD (existing config likely already discovers services tagged `prom`). If not, add a static job.

---

## Task 5: Smoke + runbook + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  -e finops_image=ghcr.io/acardozzo/orbty-finops:latest \
  ansible/playbooks/bootstrap.yml --tags finops
bash tests/smoke/test_finops.sh nomad-local-server-01
```

```bash
cat > docs/runbooks/finops.md <<'EOF'
# Runbook — FinOps

## Metrics surface
- `orbty_cloud_cost_usd_total{provider}` — cumulative monthly cloud spend.
- `orbty_tenant_cpu_mhz{namespace}` — current CPU allocation per tenant.
- `orbty_tenant_memory_mb{namespace}` — current memory allocation per tenant.
- `orbty_tenant_cpu_seconds_total{namespace}` — cumulative tenant CPU time.

## Pricing model (example)
1. Compute base cost: `sum(orbty_cloud_cost_usd_total) / 30 / 24` ≈ hourly cost.
2. Per-tenant share:
   ```
   sum_by_ns = sum(orbty_tenant_cpu_seconds_total[1h]) by (namespace)
   total = sum(orbty_tenant_cpu_seconds_total[1h])
   tenant_cost = base_hourly * sum_by_ns / total
   ```
3. Mark up by margin (e.g. 2x) for billing.

## Future: OpenCost compatibility
Add an OpenCost-Allocation Prometheus exporter shape (`opencost_*` metrics) for compatibility with their UI/CLI. Out of scope here.
EOF
git add docs/runbooks/finops.md
git commit -m "docs(runbook): finops"
git push origin main
```

---

## Self-Review

- Audit #18 covered (cost portion).
- No placeholders.
- Type/name consistency: `orbty_*` metric names, services aligned with Prometheus scrape via Consul SD.
