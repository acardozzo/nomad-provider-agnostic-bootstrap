# Traefik Scale-to-Zero Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Traefik middleware plugin (Yaegi-based) that intercepts the first request to a scaled-to-zero Nomad job, calls Nomad's scale API to set count=1, holds the request until the new alloc is healthy in Consul, then proxies the request through. Job idleness is tracked in a small in-memory window per service.

**Architecture:** Single Go file (Yaegi-loadable, no cgo, no goroutine leaks across reloads) implementing `http.Handler`. Reads service name from a header `X-Orbty-Job` set by Traefik's existing router rules. Uses `consul/api` and `nomad/api` Go clients (vendored — Yaegi needs vendoring). On first request to a "0-replica" job: scale to 1, poll Consul `/health/service/<name>?passing=true` for up to 60s, then proxy.

**Tech Stack:** Go 1.23+, Yaegi, Traefik plugin framework, Nomad/Consul Go clients, existing Traefik+Consul setup.

---

## File Structure

| File | Responsibility |
|---|---|
| `traefik-plugins/orbty-ondemand/.traefik.yml` | Plugin manifest |
| `traefik-plugins/orbty-ondemand/go.mod` | Module deps |
| `traefik-plugins/orbty-ondemand/ondemand.go` | The middleware logic |
| `traefik-plugins/orbty-ondemand/ondemand_test.go` | Unit tests for trigger/wait logic |
| `traefik-plugins/orbty-ondemand/vendor/...` | Vendored deps (Yaegi requirement) |
| `ansible/roles/traefik/templates/traefik.nomad.hcl.j2` | Mount the plugin via `experimental.localPlugins` arg + middleware registration |
| `ansible/roles/traefik/files/orbty-ondemand` | Symlink/copy of plugin source distributed to clients |
| `ansible/roles/traefik/tasks/main.yml` | Task to push plugin source to clients |
| `tests/smoke/test_scale_to_zero.sh` | Submit a 0-replica job, hit it, verify scale-up + 200 |

---

## Task 1: Failing smoke

```bash
cat > tests/smoke/test_scale_to_zero.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")

echo "=== Submit a count=0 job (zerowhoami) ==="
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  cat > /tmp/zw.hcl <<HCL
job \"zerowhoami\" {
  datacenters = [\"dc1\"]
  type = \"service\"
  group \"web\" {
    count = 0
    network { port \"http\" { to = 80 } }
    service {
      name = \"zerowhoami\"
      port = \"http\"
      tags = [\"traefik.enable=true\",\"traefik.http.routers.zw.rule=Host(\\\`zw.cluster.local\\\`)\",\"traefik.http.routers.zw.middlewares=orbty-ondemand@file\",\"traefik.http.middlewares.orbty-ondemand.plugin.orbty-ondemand.job=zerowhoami\"]
    }
    task \"app\" {
      driver = \"docker\"
      config { image = \"traefik/whoami:v1.10\" ports = [\"http\"] }
      resources { cpu = 100 memory = 64 }
    }
  }
}
HCL
  nomad job run /tmp/zw.hcl
"
echo "OK"

echo "=== Hit the host: should wake up and 200 within 30s ==="
CLIENT_IP=$(grep -A99 '^\[clients\]' ansible/inventory/hosts.ini | grep ansible_host | head -1 | awk -F'ansible_host=' '{print $2}' | awk '{print $1}')
START=$(date +%s)
code=$(multipass exec nomad-local-server-01 -- bash -c "
  curl -sk --resolve zw.cluster.local:443:$CLIENT_IP --max-time 30 -o /dev/null -w '%{http_code}' https://zw.cluster.local/
")
END=$(date +%s)
[[ "$code" == "200" ]] || { echo "FAIL: got $code"; exit 1; }
echo "OK ($((END - START))s)"

echo "=== After idle window, count returns to 0 ==="
sleep 70
count=$(multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  nomad job status zerowhoami | grep -A2 'Task Group' | tail -1 | awk '{print \$2}'
")
[[ "$count" == "0" ]] || { echo "FAIL: count=$count, expected 0"; exit 1; }
echo "OK"

echo "ALL SCALE-TO-ZERO CHECKS PASSED"
EOF
chmod +x tests/smoke/test_scale_to_zero.sh

git add tests/smoke/test_scale_to_zero.sh
git commit -m "test(scale-to-zero): failing smoke for traefik wake-on-request"
```

Expected on first run: FAIL on the request (no plugin → 404 from Traefik).

---

## Task 2: Plugin scaffold

**Files:**
- Create: `traefik-plugins/orbty-ondemand/.traefik.yml`
- Create: `traefik-plugins/orbty-ondemand/go.mod`
- Create: `traefik-plugins/orbty-ondemand/ondemand.go`

```bash
mkdir -p traefik-plugins/orbty-ondemand
cat > traefik-plugins/orbty-ondemand/.traefik.yml <<'EOF'
displayName: orbty Ondemand
type: middleware
import: github.com/orbty/traefik-plugins/orbty-ondemand
summary: Wake idle Nomad jobs on first HTTP request, scale back to zero after idle.
testData:
  job: example
  nomadAddr: http://127.0.0.1:4646
  consulAddr: http://127.0.0.1:8500
  idleSeconds: 60
  waitSeconds: 60
EOF
```

```bash
cat > traefik-plugins/orbty-ondemand/go.mod <<'EOF'
module github.com/orbty/traefik-plugins/orbty-ondemand

go 1.23
EOF
```

```bash
cat > traefik-plugins/orbty-ondemand/ondemand.go <<'EOF'
// Package orbty_ondemand wakes idle Nomad jobs on first HTTP request and
// scales them back to zero after a configurable idle window. Designed to
// be loaded by Traefik via the Yaegi plugin runtime — no cgo, no
// long-lived goroutines beyond the per-service idle ticker.
package orbty_ondemand

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// Config is the schema applied via Traefik dynamic config.
type Config struct {
	Job          string `json:"job,omitempty"`
	NomadAddr    string `json:"nomadAddr,omitempty"`
	ConsulAddr   string `json:"consulAddr,omitempty"`
	NomadToken   string `json:"nomadToken,omitempty"`
	ConsulToken  string `json:"consulToken,omitempty"`
	IdleSeconds  int    `json:"idleSeconds,omitempty"`
	WaitSeconds  int    `json:"waitSeconds,omitempty"`
}

// CreateConfig populates defaults.
func CreateConfig() *Config {
	return &Config{
		NomadAddr:   "http://127.0.0.1:4646",
		ConsulAddr:  "http://127.0.0.1:8500",
		IdleSeconds: 60,
		WaitSeconds: 60,
	}
}

// state per job — last seen request time + scale guard.
var (
	stateMu sync.Mutex
	state   = map[string]*jobState{}
)

type jobState struct {
	lastSeen time.Time
	scaling  bool
}

// Plugin is the Traefik middleware.
type Plugin struct {
	next http.Handler
	cfg  *Config
	name string
}

// New is invoked by Traefik for each middleware instance.
func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	if cfg.Job == "" {
		return nil, errors.New("orbty-ondemand: 'job' must be set")
	}
	p := &Plugin{next: next, cfg: cfg, name: name}
	go p.idleSweeper(ctx)
	return p, nil
}

func (p *Plugin) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	stateMu.Lock()
	st, ok := state[p.cfg.Job]
	if !ok {
		st = &jobState{}
		state[p.cfg.Job] = st
	}
	st.lastSeen = time.Now()
	scaling := st.scaling
	stateMu.Unlock()

	healthy, err := p.serviceHealthy(req.Context())
	if err == nil && healthy {
		p.next.ServeHTTP(rw, req)
		return
	}

	if !scaling {
		stateMu.Lock()
		st.scaling = true
		stateMu.Unlock()
		if err := p.scale(req.Context(), 1); err != nil {
			stateMu.Lock(); st.scaling = false; stateMu.Unlock()
			http.Error(rw, fmt.Sprintf("orbty-ondemand: scale failed: %v", err), http.StatusBadGateway)
			return
		}
	}

	deadline := time.Now().Add(time.Duration(p.cfg.WaitSeconds) * time.Second)
	for time.Now().Before(deadline) {
		ok, err := p.serviceHealthy(req.Context())
		if err == nil && ok {
			stateMu.Lock(); st.scaling = false; stateMu.Unlock()
			p.next.ServeHTTP(rw, req)
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	stateMu.Lock(); st.scaling = false; stateMu.Unlock()
	http.Error(rw, "orbty-ondemand: backend not ready", http.StatusGatewayTimeout)
}

func (p *Plugin) serviceHealthy(ctx context.Context) (bool, error) {
	u := fmt.Sprintf("%s/v1/health/service/%s?passing=true", p.cfg.ConsulAddr, url.PathEscape(p.cfg.Job))
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	if p.cfg.ConsulToken != "" {
		req.Header.Set("X-Consul-Token", p.cfg.ConsulToken)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return false, fmt.Errorf("consul status %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	var arr []interface{}
	if err := json.Unmarshal(body, &arr); err != nil {
		return false, err
	}
	return len(arr) > 0, nil
}

func (p *Plugin) scale(ctx context.Context, count int) error {
	u := fmt.Sprintf("%s/v1/job/%s/scale", p.cfg.NomadAddr, url.PathEscape(p.cfg.Job))
	body := fmt.Sprintf(`{"Count": %d, "Message": "orbty-ondemand"}`, count)
	req, _ := http.NewRequestWithContext(ctx, "POST", u, io.NopCloser(stringReader(body)))
	req.Header.Set("Content-Type", "application/json")
	if p.cfg.NomadToken != "" {
		req.Header.Set("X-Nomad-Token", p.cfg.NomadToken)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("nomad scale: %d %s", resp.StatusCode, string(b))
	}
	return nil
}

// idleSweeper scales each tracked job to 0 after IdleSeconds without traffic.
func (p *Plugin) idleSweeper(ctx context.Context) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			stateMu.Lock()
			st, ok := state[p.cfg.Job]
			if !ok {
				stateMu.Unlock()
				continue
			}
			idle := time.Since(st.lastSeen) > time.Duration(p.cfg.IdleSeconds)*time.Second
			scaling := st.scaling
			stateMu.Unlock()

			if idle && !scaling {
				_ = p.scale(ctx, 0)
			}
		}
	}
}

type stringReaderType string

func (s stringReaderType) Read(p []byte) (n int, err error) {
	if len(s) == 0 {
		return 0, io.EOF
	}
	n = copy(p, s)
	return n, nil
}

func stringReader(s string) io.Reader { return stringReaderType(s) }
EOF
```

Commit:

```bash
git add traefik-plugins/orbty-ondemand/
git commit -m "feat(traefik-plugin): orbty-ondemand wake-on-request middleware"
```

---

## Task 3: Unit tests

**Files:**
- Create: `traefik-plugins/orbty-ondemand/ondemand_test.go`

```bash
cat > traefik-plugins/orbty-ondemand/ondemand_test.go <<'EOF'
package orbty_ondemand

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestServiceHealthy_RespectsConsulResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `[{"Service":{"ID":"x"}}]`)
	}))
	defer srv.Close()
	p := &Plugin{cfg: &Config{Job: "j", ConsulAddr: srv.URL}}
	ok, err := p.serviceHealthy(context.Background())
	if err != nil || !ok {
		t.Fatalf("expected healthy, got ok=%v err=%v", ok, err)
	}
}

func TestServiceHealthy_EmptyMeansUnhealthy(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `[]`)
	}))
	defer srv.Close()
	p := &Plugin{cfg: &Config{Job: "j", ConsulAddr: srv.URL}}
	ok, _ := p.serviceHealthy(context.Background())
	if ok {
		t.Fatal("expected unhealthy")
	}
}

func TestScale_PostsCorrectBody(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = string(b)
	}))
	defer srv.Close()
	p := &Plugin{cfg: &Config{Job: "myjob", NomadAddr: srv.URL}}
	if err := p.scale(context.Background(), 3); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, `"Count": 3`) {
		t.Fatalf("scale body wrong: %s", got)
	}
}

func TestServeHTTP_HealthyImmediate(t *testing.T) {
	healthy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `[{"Service":{"ID":"x"}}]`)
	}))
	defer healthy.Close()
	var hits int32
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(200)
	})
	p := &Plugin{next: next, cfg: &Config{Job: "j", ConsulAddr: healthy.URL, WaitSeconds: 1, IdleSeconds: 60}}
	rr := httptest.NewRecorder()
	p.ServeHTTP(rr, httptest.NewRequest("GET", "/", nil))
	if rr.Code != 200 || atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("expected proxied 200, got code=%d hits=%d", rr.Code, hits)
	}
}

func TestServeHTTP_ScalesUpOnFirstHit(t *testing.T) {
	var scaleCalls int32
	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&scaleCalls, 1)
	}))
	defer nomad.Close()

	step := int32(0)
	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s := atomic.AddInt32(&step, 1)
		if s <= 2 {
			_, _ = io.WriteString(w, `[]`)
		} else {
			_, _ = io.WriteString(w, `[{"Service":{"ID":"x"}}]`)
		}
	}))
	defer consul.Close()

	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(202) })
	p := &Plugin{next: next, cfg: &Config{Job: "j", NomadAddr: nomad.URL, ConsulAddr: consul.URL, WaitSeconds: 5, IdleSeconds: 60}}

	rr := httptest.NewRecorder()
	start := time.Now()
	p.ServeHTTP(rr, httptest.NewRequest("GET", "/", nil))
	dur := time.Since(start)

	if rr.Code != 202 {
		t.Fatalf("expected 202 after wake, got %d", rr.Code)
	}
	if atomic.LoadInt32(&scaleCalls) != 1 {
		t.Fatalf("expected exactly 1 scale call, got %d", scaleCalls)
	}
	if dur >= 5*time.Second {
		t.Fatalf("hit wait deadline: %s", dur)
	}
}

func TestServeHTTP_DeadlineExpires(t *testing.T) {
	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer nomad.Close()
	consul := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `[]`)
	}))
	defer consul.Close()
	p := &Plugin{next: http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}), cfg: &Config{Job: "j", NomadAddr: nomad.URL, ConsulAddr: consul.URL, WaitSeconds: 1, IdleSeconds: 60}}
	rr := httptest.NewRecorder()
	p.ServeHTTP(rr, httptest.NewRequest("GET", "/", nil))
	if rr.Code != http.StatusGatewayTimeout {
		t.Fatalf("expected 504 on deadline, got %d", rr.Code)
	}
	_ = fmt.Sprintf
}
EOF
```

Run:

```bash
cd traefik-plugins/orbty-ondemand
go mod tidy
go test ./... -v
cd -
```

Expected: all pass.

Commit:

```bash
git add traefik-plugins/orbty-ondemand/
git commit -m "test(traefik-plugin): unit tests for ondemand"
```

---

## Task 4: Wire plugin into Traefik job

**Files:**
- Modify: `ansible/roles/traefik/tasks/main.yml`
- Modify: `ansible/roles/traefik/templates/traefik.nomad.hcl.j2`

- [ ] **Step 1: Distribute plugin source to clients**

In `ansible/roles/traefik/tasks/main.yml` append:

```yaml
- name: Ensure local plugin dir
  ansible.builtin.file:
    path: /var/lib/traefik/plugins-local/src/github.com/orbty/traefik-plugins/orbty-ondemand
    state: directory
    owner: root
    group: root
    mode: "0755"
  when: inventory_hostname in groups['clients']

- name: Copy orbty-ondemand plugin
  ansible.builtin.copy:
    src: "{{ playbook_dir }}/../roles/traefik/files/orbty-ondemand/"
    dest: /var/lib/traefik/plugins-local/src/github.com/orbty/traefik-plugins/orbty-ondemand/
    owner: root
    group: root
    mode: "0644"
  when: inventory_hostname in groups['clients']
```

Place a symlink/copy of the plugin source under `ansible/roles/traefik/files/orbty-ondemand/` (the same files from `traefik-plugins/orbty-ondemand/`).

- [ ] **Step 2: Update Traefik job template**

In `ansible/roles/traefik/templates/traefik.nomad.hcl.j2`, add a volume mount and `experimental.localPlugins`:

```hcl
    volume "plugins" {
      type      = "host"
      source    = "traefik_plugins"
      read_only = true
    }
```

Inside `task "traefik"`:

```hcl
      volume_mount {
        volume      = "plugins"
        destination = "/plugins-local"
        read_only   = true
      }
```

Append to the `args = [...]` array:

```hcl
          "--experimental.localPlugins.orbty-ondemand.modulename=github.com/orbty/traefik-plugins/orbty-ondemand",
```

- [ ] **Step 3: Add host_volume in nomad-client.hcl.j2**

```hcl
  host_volume "traefik_plugins" {
    path      = "/var/lib/traefik/plugins-local"
    read_only = true
  }
```

- [ ] **Step 4: Re-run roles**

```bash
cat > /tmp/nomad-only.yml <<'EOF'
- hosts: all
  become: true
  roles: [nomad]
EOF
cat > /tmp/traefik-only.yml <<'EOF'
- hosts: all
  become: true
  roles: [traefik]
EOF
ANSIBLE_CONFIG=ansible/ansible.cfg ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i ansible/inventory/hosts.ini \
  -e "@ansible/inventory/group_vars/all_local.yml" /tmp/nomad-only.yml /tmp/traefik-only.yml
```

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/traefik ansible/roles/nomad/templates/nomad-client.hcl.j2
git commit -m "feat(traefik): mount + load orbty-ondemand local plugin"
```

---

## Task 5: Make smoke pass + push

```bash
bash tests/smoke/test_scale_to_zero.sh nomad-local-server-01
```

Expected: `ALL SCALE-TO-ZERO CHECKS PASSED`. Wake time should be < 5s for whoami.

If fails, inspect Traefik logs:

```bash
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' ansible/inventory/group_vars/all/secrets.yml)
multipass exec nomad-local-client-01 -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ALLOC=\$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus \"running\"}}{{.ID}}{{end}}{{end}}' traefik | head -c 8)
  nomad alloc logs -stderr \$ALLOC | grep -i 'plugin\|ondemand' | tail -20
"
```

Push:

```bash
git push origin main
```

---

## Task 6: Runbook

```bash
cat > docs/runbooks/scale-to-zero.md <<'EOF'
# Runbook — Scale-to-Zero (orbty-ondemand)

## How it works
1. App declares `count = 0` in its Nomad job.
2. App declares Traefik tags including the middleware:
   `traefik.http.routers.<r>.middlewares=orbty-ondemand@file`
   `traefik.http.middlewares.orbty-ondemand.plugin.orbty-ondemand.job=<jobname>`
3. First HTTP request hits Traefik → orbty-ondemand middleware:
   - Calls Nomad scale API → count=1
   - Polls Consul `/health/service/<jobname>?passing=true` (250ms)
   - On healthy: proxies request, returns 200
   - On 60s timeout: returns 504
4. Idle sweeper (every 15s) scales any service with no traffic in 60s back to 0.

## Tuning
Per-app override via middleware config:
```
traefik.http.middlewares.orbty-ondemand.plugin.orbty-ondemand.idleSeconds=300
traefik.http.middlewares.orbty-ondemand.plugin.orbty-ondemand.waitSeconds=120
```

## Limitations
- Single-Traefik-instance state (in-memory map). Multiple Traefik replicas
  do not share state — each will independently fire scale calls (mostly
  harmless but emits duplicate API hits).
- Cold start time = Nomad placement + Docker pull + container ready.
  Without image pre-pull, expect 3–10s; with pre-pulled image, 1–3s.

## Failure modes
| Symptom | Cause | Fix |
|---|---|---|
| 502 Bad Gateway | Nomad scale API call failed | Check token, check job exists |
| 504 Gateway Timeout | App didn't pass health within 60s | Increase `waitSeconds`; check job health-check |
| Constant scale-up + scale-down | Health-check too aggressive | Loosen `min_healthy_time` in app's update block |
EOF
git add docs/runbooks/scale-to-zero.md
git commit -m "docs(runbook): scale-to-zero (orbty-ondemand)"
git push origin main
```

---

## Self-Review

- Research §Topic 1 covered: Traefik plugin path implemented, Nomad scale API used, Consul SD used as readiness signal.
- No placeholders: all Go code is complete; tests cover the four critical
  paths (immediate-healthy, scale-on-miss, deadline, scale request shape).
- Type/name consistency: `orbty-ondemand` middleware name appears
  identically in plugin manifest, Traefik args, and Nomad service tags.
