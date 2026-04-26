.PHONY: help lint lint-tf lint-ansible lint-shell lint-jinja syntax-check fmt all

ANSIBLE_IMAGE ?= quay.io/ansible/creator-ee:latest
ROOT := $(shell pwd)

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

all: lint syntax-check ## Run every static check

lint: lint-tf lint-ansible lint-shell lint-jinja ## Run all linters

lint-tf: ## terraform fmt -check
	terraform -chdir=terraform fmt -check -recursive
	terraform -chdir=terraform/modules/providers/vultr fmt -check
	terraform -chdir=terraform/modules/providers/linode fmt -check

lint-ansible: ## ansible-lint via container (no local ansible needed)
	docker run --rm -v "$(ROOT):/work" -w /work $(ANSIBLE_IMAGE) ansible-lint ansible/

lint-shell: ## bash -n on every script
	@set -e; for f in bin/* tests/smoke/*.sh; do echo "  $$f"; bash -n "$$f"; done

lint-jinja: ## jinja parse on every .j2
	@python3 -c "import jinja2,sys,glob; e=jinja2.Environment(); [e.parse(open(p).read()) for p in glob.glob('ansible/**/*.j2', recursive=True)]; print('jinja ok')"

syntax-check: ## ansible-playbook --syntax-check via container
	@printf '[servers]\nlocalhost\n[clients]\nlocalhost\n' > /tmp/stub-inv
	docker run --rm -v "$(ROOT):/work" -v /tmp/stub-inv:/tmp/stub-inv -w /work $(ANSIBLE_IMAGE) \
		ansible-playbook --syntax-check -i /tmp/stub-inv ansible/playbooks/bootstrap.yml
	docker run --rm -v "$(ROOT):/work" -w /work $(ANSIBLE_IMAGE) \
		ansible-playbook --syntax-check ansible/playbooks/secrets.yml

fmt: ## Format all .tf
	terraform -chdir=terraform fmt -recursive

# --- Local dev (Docker compose: Traefik + whoami fast smoke) ---

local-traefik-up: ## Bring up dev/docker compose stack
	docker compose -f dev/docker/compose.yml up -d --wait

local-traefik-down: ## Tear down dev/docker compose stack
	docker compose -f dev/docker/compose.yml down -v

local-traefik-smoke: ## Run smoke against dev/docker compose stack
	./tests/smoke/test_local_traefik.sh

# --- Local dev (Multipass: full 5-VM cluster replica) ---

local-cluster-up: ## Spin up 5-VM local cluster via Multipass and run Ansible bootstrap
	./bin/local-up

local-cluster-down: ## Destroy the 5-VM local cluster
	./bin/local-down
