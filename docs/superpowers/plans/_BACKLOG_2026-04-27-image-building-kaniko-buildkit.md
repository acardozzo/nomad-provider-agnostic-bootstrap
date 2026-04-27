# Image Building (Kaniko + BuildKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide an in-cluster image-build pipeline so apps can `git push` and get an image in the orbty registry without external CI. Two paths: Kaniko (rootless, no daemon) for simple Dockerfile-based builds, BuildKit (daemonized, faster cache) for advanced scenarios. Closes audit #15.

**Architecture:** Two parameterized batch jobs in Nomad — `kaniko-build` and `buildkit-build`. Each accepts a `payload` of: git_repo, git_ref, dockerfile_path, image_tag. Auth to the orbty registry via secrets in env. Webhook trigger comes via Atlantis (or a tiny custom listener); not in scope here.

**Tech Stack:** Kaniko (`gcr.io/kaniko-project/executor`), BuildKit (`moby/buildkit`), Nomad parameterized batch.

---

## File Structure

| File | Responsibility |
|---|---|
| `ansible/roles/image-build/templates/kaniko.nomad.hcl.j2` | parameterized batch |
| `ansible/roles/image-build/templates/buildkit.nomad.hcl.j2` | parameterized batch (uses buildctl) |
| `ansible/roles/image-build/tasks/main.yml` | submit jobs |
| `bin/build-image` | helper: dispatches `kaniko-build` with git+dockerfile args |
| `tests/smoke/test_image_build.sh` | dispatch a build of a sample repo, verify image lands in registry |

---

## Task 1: Failing smoke

```bash
cat > tests/smoke/test_image_build.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 <vm>" >&2; exit 64; fi
VM="$1"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml")
USER=$(awk '$1=="registry_user:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml" | tr -d \")
PASS=$(awk '$1=="registry_password:" {print $2}' "$(dirname "${BASH_SOURCE[0]}")/../../ansible/inventory/group_vars/all/secrets.yml" | tr -d \")

echo "=== dispatch kaniko-build ==="
PAYLOAD=$(printf '{"git_repo":"https://github.com/dockersamples/example-voting-app.git","git_ref":"main","dockerfile":"vote/Dockerfile","context":"vote","image":"registry.cluster.local/smoke/vote:1"}' | base64)
multipass exec "$VM" -- bash -c "
  export NOMAD_TOKEN='$NOMAD_TOKEN'
  ID=\$(nomad job dispatch -payload-file=- kaniko-build <<< '$PAYLOAD' | grep 'Dispatched Job ID' | awk '{print \$NF}')
  echo \$ID
  for i in \$(seq 1 90); do
    s=\$(nomad job status \$ID | grep -m1 'Status\s*=' | awk '{print \$NF}')
    [[ \"\$s\" == \"dead\" ]] && break
    sleep 5
  done
  ALLOC=\$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' \$ID | head -c 8)
  nomad alloc logs \$ALLOC | tail -10
"

echo "=== image lands in registry ==="
multipass exec "$VM" -- curl -sk -u "$USER:$PASS" https://registry.cluster.local/v2/smoke/vote/tags/list | grep -q '"1"' || { echo FAIL; exit 1; }
echo OK

echo "ALL IMAGE BUILD CHECKS PASSED"
EOF
chmod +x tests/smoke/test_image_build.sh
git add tests/smoke/test_image_build.sh
git commit -m "test(image-build): failing smoke for kaniko build"
```

---

## Task 2: Kaniko parameterized batch

```bash
mkdir -p ansible/roles/image-build/{tasks,templates}
cat > ansible/roles/image-build/templates/kaniko.nomad.hcl.j2 <<'EOF'
job "kaniko-build" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  parameterized {
    payload       = "required"
    meta_required = []
  }

  group "build" {
    constraint { attribute = "${node.class}" operator = "=" value = "client" }

    task "build" {
      driver = "docker"

      env {
        REGISTRY_USER = "{{ registry_user }}"
        REGISTRY_PASS = "{{ registry_password }}"
      }

      dispatch_payload { file = "args.json" }

      config {
        image      = "gcr.io/kaniko-project/executor:v1.23.2-debug"
        entrypoint = ["sh", "-c"]
        args = [
<<-CMD
set -e
P=$(cat /local/args.json)
GIT_REPO=$(echo "$P" | jq -r .git_repo)
GIT_REF=$(echo "$P" | jq -r .git_ref)
DF=$(echo "$P" | jq -r .dockerfile)
CTX=$(echo "$P" | jq -r .context)
IMG=$(echo "$P" | jq -r .image)
mkdir -p /workspace
git clone --depth 1 --branch "$GIT_REF" "$GIT_REPO" /workspace
mkdir -p /kaniko/.docker
cat > /kaniko/.docker/config.json <<JSON
{"auths":{"registry.cluster.local":{"auth":"$(echo -n $REGISTRY_USER:$REGISTRY_PASS | base64 -w0)"}}}
JSON
/kaniko/executor --context=/workspace/$CTX --dockerfile=/workspace/$DF --destination=$IMG --insecure --skip-tls-verify
CMD
        ]
      }

      resources { cpu = 1000; memory = 1024 }
    }
  }
}
EOF
git add ansible/roles/image-build/templates/kaniko.nomad.hcl.j2
git commit -m "feat(image-build): kaniko parameterized batch"
```

---

## Task 3: BuildKit (alternative, faster cache)

```bash
cat > ansible/roles/image-build/templates/buildkit.nomad.hcl.j2 <<'EOF'
job "buildkit-build" {
  datacenters = ["{{ nomad_datacenter }}"]
  type        = "batch"

  parameterized {
    payload = "required"
  }

  group "build" {
    constraint { attribute = "${node.class}" operator = "=" value = "client" }

    task "build" {
      driver = "docker"

      env {
        REGISTRY_USER = "{{ registry_user }}"
        REGISTRY_PASS = "{{ registry_password }}"
      }

      dispatch_payload { file = "args.json" }

      config {
        image      = "moby/buildkit:rootless"
        privileged = true
        entrypoint = ["sh", "-c"]
        args = [
<<-CMD
set -e
apk add --no-cache jq git curl
P=$(cat /local/args.json)
GIT_REPO=$(echo "$P" | jq -r .git_repo)
GIT_REF=$(echo "$P" | jq -r .git_ref)
DF=$(echo "$P" | jq -r .dockerfile)
CTX=$(echo "$P" | jq -r .context)
IMG=$(echo "$P" | jq -r .image)
mkdir -p /workspace
git clone --depth 1 --branch "$GIT_REF" "$GIT_REPO" /workspace
mkdir -p ~/.docker
cat > ~/.docker/config.json <<JSON
{"auths":{"registry.cluster.local":{"auth":"$(echo -n $REGISTRY_USER:$REGISTRY_PASS | base64 -w0)"}}}
JSON
buildctl-daemonless.sh build \
  --frontend=dockerfile.v0 \
  --local context=/workspace/$CTX \
  --local dockerfile=/workspace/$(dirname $DF) \
  --opt filename=$(basename $DF) \
  --output type=image,name=$IMG,push=true,registry.insecure=true
CMD
        ]
      }

      resources { cpu = 2000; memory = 2048 }
    }
  }
}
EOF
git add ansible/roles/image-build/templates/buildkit.nomad.hcl.j2
git commit -m "feat(image-build): buildkit parameterized batch"
```

---

## Task 4: Submit + helper script

```bash
cat > ansible/roles/image-build/tasks/main.yml <<'EOF'
---
- name: Submit kaniko-build
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'kaniko.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true

- name: Submit buildkit-build
  ansible.builtin.shell: nomad job run -
  args: { stdin: "{{ lookup('template', 'buildkit.nomad.hcl.j2') }}", executable: /bin/bash }
  environment:
    NOMAD_ADDR: "http://{{ hostvars[groups['servers'][0]].ansible_host }}:4646"
    NOMAD_TOKEN: "{{ nomad_bootstrap_token }}"
  delegate_to: localhost
  become: false
  run_once: true
  changed_when: true
EOF

cat > bin/build-image <<'EOF'
#!/usr/bin/env bash
# Usage: bin/build-image kaniko|buildkit <git_repo> <git_ref> <dockerfile> <context> <image>
set -euo pipefail
[[ $# -eq 6 ]] || { echo "usage: $0 kaniko|buildkit <git_repo> <git_ref> <dockerfile> <context> <image>"; exit 64; }
TOOL=$1; REPO=$2; REF=$3; DF=$4; CTX=$5; IMG=$6
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOMAD_TOKEN=$(awk '$1=="nomad_bootstrap_token:" {print $2}' "$ROOT_DIR/ansible/inventory/group_vars/all/secrets.yml")
SERVER_IP=$(grep -A99 '^\[servers\]' "$ROOT_DIR/ansible/inventory/hosts.ini" | grep ansible_host | head -1 | awk -F'ansible_host=' '{print $2}' | awk '{print $1}')
PAYLOAD=$(printf '{"git_repo":"%s","git_ref":"%s","dockerfile":"%s","context":"%s","image":"%s"}' "$REPO" "$REF" "$DF" "$CTX" "$IMG")
NOMAD_ADDR="http://$SERVER_IP:4646" NOMAD_TOKEN="$NOMAD_TOKEN" \
  nomad job dispatch -payload-file=- "${TOOL}-build" <<< "$PAYLOAD"
EOF
chmod +x bin/build-image

git add ansible/roles/image-build/tasks/main.yml bin/build-image
git commit -m "feat(image-build): submit + bin/build-image helper"
```

---

## Task 5: Run + smoke + runbook + push

```bash
ansible-playbook -i ansible/inventory/hosts.ini -e "@ansible/inventory/group_vars/all_local.yml" \
  ansible/playbooks/bootstrap.yml --tags image-build
bash tests/smoke/test_image_build.sh nomad-local-server-01
```

```bash
cat > docs/runbooks/image-build.md <<'EOF'
# Runbook — Image Building

## Two engines
- **Kaniko** — rootless, no daemon, slightly slower, fits Firecracker microVM constraints.
- **BuildKit** — faster (parallelism, cache mounts), needs privileged container today (rootless mode improving).

## Triggering a build
```bash
bin/build-image kaniko \
  https://github.com/orbty/sample.git main \
  Dockerfile . \
  registry.cluster.local/orbty/sample:v1.0.0
```

## Caching strategy
- Kaniko: layer cache to a registry side-bucket (`--cache=true --cache-repo=<bucket>`).
- BuildKit: `--export-cache type=registry,ref=<image>:cache`.

## Wiring to GitOps
1. Add a webhook (GitHub or Atlantis) that on `push` to a watched branch
   dispatches `kaniko-build` with the right payload.
2. The build dispatches a separate Nomad job to deploy the new image
   (Atlantis `apply` of a TF/ansible change, or a direct `nomad job run`).

## Security
- Trivy scans every image in registry daily (see `_BACKLOG_..-trivy-continuous-scanning.md`).
- Sign images with cosign — out of scope, add later.
EOF
git add docs/runbooks/image-build.md
git commit -m "docs(runbook): image build"
git push origin main
```

---

## Self-Review

- Audit #15 covered (Kaniko + BuildKit, no kpack — buildpacks deferred).
- No placeholders.
- Type/name consistency: payload schema (`git_repo`, `git_ref`, `dockerfile`, `context`, `image`) consistent across both engines and the bin script.
