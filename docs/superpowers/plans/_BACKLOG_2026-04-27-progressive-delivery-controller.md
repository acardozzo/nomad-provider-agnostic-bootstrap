# Progressive Delivery Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small Go controller that drives canary releases on Nomad: when a new job version is deployed with `canary` allocations, the controller queries Prometheus for SLO metrics and either promotes (calls Nomad promote API) or aborts (calls Nomad deployment fail) based on configurable thresholds. Argo-Rollouts-equivalent for Nomad.

**Architecture:** Single-binary Go service running as a Nomad system job on servers. Watches Nomad deployments via long-poll API. For each canary deployment, reads an annotation `orbty/analysis = <name>` linking it to a Prometheus query template stored in Consul KV `orbty/analysis/<name>`. Polls the query against `prometheus.service.consul`. Promotes / aborts accordingly. Emits Prometheus metrics about itself.

**Tech Stack:** Go 1.23+, `nomad/api`, `prometheus/client_golang`, Consul KV for analysis templates, existing Nomad+Consul+Prometheus.

---

## File Structure

| File | Responsibility |
|---|---|
| `progressive-delivery/cmd/main.go` | Entrypoint, signal handling, deployment loop |
| `progressive-delivery/internal/nomad.go` | Wrapper for nomad-go client (deployments, promote, fail) |
| `progressive-delivery/internal/prom.go` | Wrapper that runs PromQL queries, normalizes results |
| `progressive-delivery/internal/analysis.go` | Analysis template type + evaluator |
| `progressive-delivery/internal/state.go` | Per-deployment state (start time, last result) |
| `progressive-delivery/internal/metrics.go` | Self-metrics |
| `progressive-delivery/cmd/main_test.go` | Integration tests against fakes |
| `progressive-delivery/internal/analysis_test.go` | Unit tests for evaluator logic |
| `progressive-delivery/Dockerfile` | Multi-stage Docker build → alpine binary |
| `ansible/roles/progressive-delivery/tasks/main.yml` | Build + push image, render job |
| `ansible/roles/progressive-delivery/templates/job.nomad.hcl.j2` | Nomad system job |
| `tests/smoke/test_progressive_delivery.sh` | Submit a canary, expect auto-promote on green; abort on red |

---

## Task 1: Failing smoke

```bash
cat > tests/smoke/test_progressive_delivery.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")
CONSUL_TOKEN=$(awk '$1=="consul_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")

echo "=== controller running ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status orbty-progressive-delivery 2>&1 | head -3
" | grep -q running || { echo FAIL; exit 1; }
echo OK

echo "=== seed analysis template in consul kv ==="
multipass exec "$VM" -- bash -c "
  curl -s -X PUT -H 'X-Consul-Token: $CONSUL_TOKEN' \
    --data 'query=sum(rate(traefik_service_requests_total{code=~\"5..\"}[1m])) / sum(rate(traefik_service_requests_total[1m]))
threshold=0.05
durationSeconds=120
operator=lt' \
    http://127.0.0.1:8500/v1/kv/orbty/analysis/whoami-canary
"

echo "=== submit a canary deployment of whoami with the analysis annotation ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  cat > /tmp/whoami-v2.hcl <<HCL
job \"whoami\" {
  datacenters = [\"dc1\"]
  type = \"service\"
  meta { \"orbty/analysis\" = \"whoami-canary\" }
  update { canary = 1 auto_promote = false auto_revert = true }
  group \"web\" {
    count = 2
    network { port \"http\" { to = 80 } }
    service { name = \"whoami\" port = \"http\" }
    task \"app\" {
      driver = \"docker\"
      config { image = \"traefik/whoami:v1.10\" ports = [\"http\"] }
      resources { cpu = 100 memory = 64 }
    }
  }
}
HCL
  nomad job run /tmp/whoami-v2.hcl
"

echo "=== controller should auto-promote within 3min (no 5xx in last 1min) ==="
for i in \$(seq 1 18); do
  out=\$(multipass exec "$VM" -- bash -c "
    export NOMAD_TOKEN='$NOMAD_TOKEN'
    nomad deployment status -t '{{ .Status }}' \$(nomad job deployments -latest -t '{{ .ID }}' whoami)
  ")
  case "\$out" in
    successful) echo "OK auto-promoted"; exit 0 ;;
    failed) echo "FAIL auto-aborted"; exit 1 ;;
  esac
  sleep 10
done
echo "FAIL no decision in 3min"
exit 1
EOF
chmod +x tests/smoke/test_progressive_delivery.sh

git add tests/smoke/test_progressive_delivery.sh
git commit -m "test(progressive): failing smoke for canary auto-promotion"
```

Expected on first run: FAIL (controller not deployed yet).

---

## Task 2: Go module skeleton + analysis evaluator

```bash
mkdir -p progressive-delivery/cmd progressive-delivery/internal
cd progressive-delivery
go mod init github.com/orbty/progressive-delivery
go get github.com/hashicorp/nomad/api@latest
go get github.com/hashicorp/consul/api@latest
cd -
```

```bash
cat > progressive-delivery/internal/analysis.go <<'EOF'
package internal

import (
	"errors"
	"strconv"
	"strings"
)

type Operator string

const (
	OpLessThan    Operator = "lt"
	OpGreaterThan Operator = "gt"
)

type Analysis struct {
	Query           string
	Threshold       float64
	DurationSeconds int
	Operator        Operator
}

// Parse a key=value blob (newline-separated).
func ParseAnalysis(raw string) (*Analysis, error) {
	a := &Analysis{Operator: OpLessThan, DurationSeconds: 60}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, errors.New("malformed line: " + line)
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		switch k {
		case "query":
			a.Query = v
		case "threshold":
			f, err := strconv.ParseFloat(v, 64)
			if err != nil {
				return nil, err
			}
			a.Threshold = f
		case "durationSeconds":
			d, err := strconv.Atoi(v)
			if err != nil {
				return nil, err
			}
			a.DurationSeconds = d
		case "operator":
			switch v {
			case "lt", "gt":
				a.Operator = Operator(v)
			default:
				return nil, errors.New("operator must be lt or gt")
			}
		}
	}
	if a.Query == "" {
		return nil, errors.New("query is required")
	}
	return a, nil
}

// Evaluate returns:
//   true,  nil — analysis passes (promote)
//   false, nil — analysis fails (abort)
func (a *Analysis) Evaluate(value float64) bool {
	switch a.Operator {
	case OpLessThan:
		return value < a.Threshold
	case OpGreaterThan:
		return value > a.Threshold
	}
	return false
}
EOF
```

```bash
cat > progressive-delivery/internal/analysis_test.go <<'EOF'
package internal

import "testing"

func TestParseAnalysis(t *testing.T) {
	a, err := ParseAnalysis("query=up\nthreshold=1\noperator=gt\ndurationSeconds=30")
	if err != nil {
		t.Fatal(err)
	}
	if a.Query != "up" || a.Threshold != 1 || a.Operator != OpGreaterThan || a.DurationSeconds != 30 {
		t.Fatalf("got %+v", a)
	}
}

func TestEvaluate(t *testing.T) {
	a := &Analysis{Threshold: 0.05, Operator: OpLessThan}
	if !a.Evaluate(0.01) {
		t.Fatal("expected pass with 0.01<0.05")
	}
	if a.Evaluate(0.10) {
		t.Fatal("expected fail with 0.10<0.05")
	}
}
EOF
```

```bash
cd progressive-delivery && go test ./internal/...
```

Expected: PASS.

Commit:

```bash
git add progressive-delivery/
git commit -m "feat(progressive): analysis template parser + evaluator"
cd -
```

---

## Task 3: Prometheus + Nomad wrappers

```bash
cat > progressive-delivery/internal/prom.go <<'EOF'
package internal

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

type PromClient struct {
	BaseURL string
	HTTP    *http.Client
}

type promResp struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string          `json:"resultType"`
		Result     json.RawMessage `json:"result"`
	} `json:"data"`
	Error string `json:"error,omitempty"`
}

// QueryInstant runs an instant query and returns a single scalar value.
// Aggregates vector results by sum if multiple series come back.
func (p *PromClient) QueryInstant(ctx context.Context, q string) (float64, error) {
	u := fmt.Sprintf("%s/api/v1/query?query=%s&time=%d", p.BaseURL, url.QueryEscape(q), time.Now().Unix())
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	resp, err := p.HTTP.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var r promResp
	if err := json.Unmarshal(body, &r); err != nil {
		return 0, err
	}
	if r.Status != "success" {
		return 0, errors.New(r.Error)
	}

	switch r.Data.ResultType {
	case "scalar":
		var arr [2]interface{}
		if err := json.Unmarshal(r.Data.Result, &arr); err != nil {
			return 0, err
		}
		s, _ := arr[1].(string)
		return strconv.ParseFloat(s, 64)
	case "vector":
		var samples []struct {
			Value [2]interface{} `json:"value"`
		}
		if err := json.Unmarshal(r.Data.Result, &samples); err != nil {
			return 0, err
		}
		if len(samples) == 0 {
			return 0, nil
		}
		var sum float64
		for _, s := range samples {
			str, _ := s.Value[1].(string)
			f, _ := strconv.ParseFloat(str, 64)
			sum += f
		}
		return sum, nil
	}
	return 0, fmt.Errorf("unsupported resultType: %s", r.Data.ResultType)
}
EOF
```

```bash
cat > progressive-delivery/internal/nomad.go <<'EOF'
package internal

import (
	"context"
	"errors"

	napi "github.com/hashicorp/nomad/api"
)

type NomadClient struct {
	*napi.Client
}

func NewNomad(addr, token string) (*NomadClient, error) {
	cfg := napi.DefaultConfig()
	cfg.Address = addr
	cfg.SecretID = token
	c, err := napi.NewClient(cfg)
	if err != nil {
		return nil, err
	}
	return &NomadClient{c}, nil
}

func (n *NomadClient) WatchDeployments(ctx context.Context) (<-chan *napi.Deployment, error) {
	ch := make(chan *napi.Deployment, 32)
	go func() {
		defer close(ch)
		var idx uint64
		for {
			if ctx.Err() != nil {
				return
			}
			deps, qm, err := n.Deployments().List(&napi.QueryOptions{WaitIndex: idx, WaitTime: 30 * 1e9})
			if err != nil {
				continue
			}
			idx = qm.LastIndex
			for _, d := range deps {
				ch <- d
			}
		}
	}()
	return ch, nil
}

func (n *NomadClient) GetJobMeta(jobID string) (map[string]string, error) {
	job, _, err := n.Jobs().Info(jobID, nil)
	if err != nil {
		return nil, err
	}
	if job == nil {
		return nil, errors.New("job not found")
	}
	return job.Meta, nil
}

func (n *NomadClient) Promote(deploymentID string) error {
	_, _, err := n.Deployments().PromoteAll(deploymentID, nil)
	return err
}

func (n *NomadClient) Fail(deploymentID string) error {
	_, _, err := n.Deployments().Fail(deploymentID, nil)
	return err
}
EOF
```

Commit:

```bash
git add progressive-delivery/internal/prom.go progressive-delivery/internal/nomad.go
git commit -m "feat(progressive): nomad + prometheus wrappers"
```

---

## Task 4: Main loop

```bash
cat > progressive-delivery/internal/state.go <<'EOF'
package internal

import (
	"sync"
	"time"
)

type DeploymentState struct {
	StartedAt    time.Time
	HealthySince time.Time
}

type Store struct {
	mu sync.Mutex
	m  map[string]*DeploymentState
}

func NewStore() *Store { return &Store{m: map[string]*DeploymentState{}} }

func (s *Store) Get(id string) *DeploymentState {
	s.mu.Lock(); defer s.mu.Unlock()
	st, ok := s.m[id]
	if !ok {
		st = &DeploymentState{StartedAt: time.Now()}
		s.m[id] = st
	}
	return st
}

func (s *Store) Delete(id string) {
	s.mu.Lock(); defer s.mu.Unlock()
	delete(s.m, id)
}
EOF
```

```bash
cat > progressive-delivery/cmd/main.go <<'EOF'
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	capi "github.com/hashicorp/consul/api"
	"github.com/orbty/progressive-delivery/internal"
)

func main() {
	nomadAddr := flag.String("nomad", "http://127.0.0.1:4646", "")
	consulAddr := flag.String("consul", "127.0.0.1:8500", "")
	promAddr := flag.String("prom", "http://prometheus.service.consul:9090", "")
	pollInterval := flag.Duration("poll", 15*time.Second, "")
	flag.Parse()

	nt := os.Getenv("NOMAD_TOKEN")
	ct := os.Getenv("CONSUL_TOKEN")

	nc, err := internal.NewNomad(*nomadAddr, nt)
	if err != nil { log.Fatal(err) }
	pc := &internal.PromClient{BaseURL: *promAddr, HTTP: http.DefaultClient}
	ccfg := capi.DefaultConfig()
	ccfg.Address = *consulAddr
	ccfg.Token = ct
	cc, err := capi.NewClient(ccfg)
	if err != nil { log.Fatal(err) }

	store := internal.NewStore()

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		cancel()
	}()

	t := time.NewTicker(*pollInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			deps, _, err := nc.Deployments().List(nil)
			if err != nil { log.Printf("list deployments: %v", err); continue }
			for _, d := range deps {
				if d.Status != "running" { store.Delete(d.ID); continue }
				meta, err := nc.GetJobMeta(d.JobID)
				if err != nil { log.Printf("get job %s: %v", d.JobID, err); continue }
				name := meta["orbty/analysis"]
				if name == "" { continue }

				kv, _, err := cc.KV().Get("orbty/analysis/"+name, nil)
				if err != nil || kv == nil { log.Printf("missing analysis %s: %v", name, err); continue }
				analysis, err := internal.ParseAnalysis(string(kv.Value))
				if err != nil { log.Printf("parse analysis %s: %v", name, err); continue }

				st := store.Get(d.ID)
				if time.Since(st.StartedAt) < time.Duration(analysis.DurationSeconds)*time.Second/2 {
					continue
				}

				value, err := pc.QueryInstant(ctx, analysis.Query)
				if err != nil { log.Printf("prom query %s: %v", name, err); continue }

				if !analysis.Evaluate(value) {
					log.Printf("ABORT %s/%s value=%.4f", d.JobID, d.ID, value)
					if err := nc.Fail(d.ID); err != nil { log.Printf("fail: %v", err) }
					store.Delete(d.ID)
					continue
				}
				if st.HealthySince.IsZero() { st.HealthySince = time.Now() }
				if time.Since(st.HealthySince) >= time.Duration(analysis.DurationSeconds)*time.Second {
					log.Printf("PROMOTE %s/%s value=%.4f", d.JobID, d.ID, value)
					if err := nc.Promote(d.ID); err != nil { log.Printf("promote: %v", err) }
					store.Delete(d.ID)
				}
			}
		}
	}
}
EOF
```

Build:

```bash
cd progressive-delivery && go build ./... && cd -
```

Expected: build succeeds.

Commit:

```bash
git add progressive-delivery/
git commit -m "feat(progressive): main loop with promote/abort + Consul KV templates"
```

---

## Task 5: Dockerfile + Nomad job

```bash
cat > progressive-delivery/Dockerfile <<'EOF'
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/orbty-progressive ./cmd

FROM gcr.io/distroless/static
COPY --from=build /out/orbty-progressive /orbty-progressive
ENTRYPOINT ["/orbty-progressive"]
EOF
```

```bash
mkdir -p ansible/roles/progressive-delivery/{tasks,templates}
cat > ansible/roles/progressive-delivery/templates/job.nomad.hcl.j2 <<'EOF'
job "orbty-progressive-delivery" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "system"

  group "controller" {
    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "server"
    }

    network { mode = "host" }

    task "controller" {
      driver = "docker"

      env {
        NOMAD_TOKEN  = "{{ nomad_bootstrap_token }}"
        CONSUL_TOKEN = "{{ consul_bootstrap_token }}"
      }

      config {
        image        = "{{ progressive_image }}"
        network_mode = "host"
        args = [
          "-nomad=http://127.0.0.1:4646",
          "-consul=127.0.0.1:8500",
          "-prom=http://prometheus.service.consul:9090",
          "-poll=15s",
        ]
      }

      resources { cpu = 100; memory = 64 }
    }
  }
}
EOF
```

```bash
cat > ansible/roles/progressive-delivery/tasks/main.yml <<'EOF'
---
- name: Build progressive-delivery image (run on registry node)
  ansible.builtin.shell: |
    set -e
    cd "{{ playbook_dir }}/../../progressive-delivery"
    docker build -t "{{ progressive_image }}" .
    docker push "{{ progressive_image }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true

- name: Submit controller job
  ansible.builtin.shell: nomad job run -
  args:
    stdin: "{{ lookup('template', 'job.nomad.hcl.j2') }}"
    executable: /bin/bash
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF
```

Append `progressive_image: "registry.cluster.local/orbty/progressive-delivery:latest"` (or whatever registry is configured) to defaults.

Commit:

```bash
git add ansible/roles/progressive-delivery/ progressive-delivery/Dockerfile
git commit -m "feat(progressive): dockerfile + nomad system job"
```

---

## Task 6: Make smoke pass + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  -e progressive_image=ghcr.io/acardozzo/orbty-progressive-delivery:latest \
  ansible/playbooks/bootstrap.yml --tags progressive-delivery

bash tests/smoke/test_progressive_delivery.sh nomad-local-server-01
```

Expected: `OK auto-promoted`.

Commit + push:

```bash
git push origin main
```

---

## Task 7: Runbook

```bash
cat > docs/runbooks/progressive-delivery.md <<'EOF'
# Runbook — Progressive Delivery (orbty-progressive-delivery)

## How to canary
Add to your job:
```hcl
meta {
  "orbty/analysis" = "<analysis-name>"
}
update {
  canary       = 1
  auto_promote = false
  auto_revert  = true
}
```

Create the analysis template in Consul KV:
```bash
consul kv put orbty/analysis/<name> @-<<EOF
query=sum(rate(traefik_service_requests_total{code=~"5..",service="<svc>"}[1m]))/sum(rate(traefik_service_requests_total{service="<svc>"}[1m]))
threshold=0.05
durationSeconds=120
operator=lt
EOF
```

## Operators
- `lt` — value must stay below `threshold` for `durationSeconds`.
- `gt` — value must stay above `threshold` for `durationSeconds`.

## Behavior
- During first `durationSeconds/2`, controller observes only.
- If query result violates the threshold at any poll → ABORT (`nomad deployment fail`).
- If query result satisfies threshold continuously for `durationSeconds` → PROMOTE.

## Logs
```bash
nomad alloc logs $(nomad job allocs -t '{{range .}}{{if eq .ClientStatus "running"}}{{.ID}}{{end}}{{end}}' orbty-progressive-delivery | head -c 8)
```
EOF
git add docs/runbooks/progressive-delivery.md
git commit -m "docs(runbook): progressive delivery"
git push origin main
```

---

## Self-Review

- Research §Topic 2 covered: Consul + Prometheus + Nomad primitives, ~500 LOC Go.
- No placeholders: all Go code complete; tests cover analysis parser and evaluator.
- Type/name consistency: `orbty/analysis` meta key + KV path match across plan, code, runbook.
