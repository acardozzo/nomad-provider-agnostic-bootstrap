# Production Ingress (TLS + Hostname Routing) — Design Spec

**Date:** 2026-04-26
**Status:** Approved (auto mode)
**Scope:** Traefik with Let's Encrypt ACME, hostname routing, dashboard auth,
HTTP→HTTPS redirect, post-deploy live verification.

## Problem

Today Traefik runs with `--api.insecure=true` on `:8080`, exposes the dashboard
to the public IP without auth, has no TLS, and routes the sample app on a path
prefix. The cluster cannot serve a real domain.

## Goal

After `bin/bootstrap`:

1. Traefik obtains and renews Let's Encrypt certificates automatically via
   HTTP-01 for one or more configured hostnames.
2. Plain HTTP redirects to HTTPS at the entrypoint level.
3. The dashboard is reachable only over HTTPS at a configurable hostname,
   protected by HTTP basic-auth.
4. The sample `whoami` app is routed by `Host(...)` rule, not path prefix.
5. `bin/bootstrap` ends with a smoke test that asserts:
   - `https://<traefik_domain>/whoami` returns 200,
   - `http://<traefik_domain>/whoami` returns 301/308 to HTTPS,
   - The dashboard host returns 401 without credentials and 200 with them.

## Non-goals

- DNS-01 / wildcard certificates. HTTP-01 is sufficient because port 80 is
  already public on every client.
- Multi-cert-resolver setup. One ACME resolver, one email.
- Cert export, mTLS to backends, or a private CA.

## Configuration surface (new `group_vars/all.yml` keys)

```yaml
traefik_domain: "example.com"          # apex/host used for whoami
traefik_dashboard_host: "traefik.example.com"
acme_email: "ops@example.com"
acme_storage: "/opt/traefik/acme.json"
dashboard_basic_auth_user: "admin"
dashboard_basic_auth_password: "{{ vault_dashboard_password }}"   # generated locally if unset
```

`traefik_domain` and `acme_email` are required; bootstrap fails fast with a
clear error if they are placeholders. They are also added to
`terraform.tfvars.example` and the README.

## Traefik job changes

`ansible/roles/traefik/templates/traefik.nomad.hcl.j2`:

- Drop `--api.insecure=true`.
- Add entrypoint `web` (`:80`) with redirection to `websecure`.
- Add entrypoint `websecure` (`:443`) with default cert resolver.
- Add cert resolver `le`:
  ```
  --certificatesresolvers.le.acme.email={{ acme_email }}
  --certificatesresolvers.le.acme.storage=/etc/traefik/acme.json
  --certificatesresolvers.le.acme.httpchallenge=true
  --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
  ```
- Mount a host volume for `acme.json` (mode 0600, owned by the task) so certs
  survive job restarts. A new Ansible task pre-creates the directory and file
  with the right perms.
- Dashboard exposed via dynamic Consul Catalog tags on Traefik itself:
  ```
  traefik.enable=true
  traefik.http.routers.dashboard.rule=Host(`{{ traefik_dashboard_host }}`)
  traefik.http.routers.dashboard.entrypoints=websecure
  traefik.http.routers.dashboard.tls.certresolver=le
  traefik.http.routers.dashboard.service=api@internal
  traefik.http.routers.dashboard.middlewares=dashboard-auth
  traefik.http.middlewares.dashboard-auth.basicauth.users=<htpasswd>
  ```
- `--api.insecure` removed; `--api.dashboard=true` kept.
- Drop the static `:8080` host port — dashboard now lives behind 443.

## Sample app changes

`ansible/roles/sample_app/templates/whoami.nomad.hcl.j2`:

- Replace path-prefix tags with:
  ```
  traefik.enable=true
  traefik.http.routers.whoami.rule=Host(`{{ traefik_domain }}`) && PathPrefix(`/whoami`)
  traefik.http.routers.whoami.entrypoints=websecure
  traefik.http.routers.whoami.tls.certresolver=le
  ```

## Bootstrap flow

`bin/bootstrap`:

```
render-inventory
ansible-playbook secrets.yml          # from security-baseline plan
ansible-playbook bootstrap.yml
tests/smoke/test_ingress_assets.sh    # already exists
tests/smoke/test_tls_ingress.sh       # NEW — live HTTP/HTTPS asserts
```

The new smoke test reads `traefik_domain` and `traefik_dashboard_host` from
`group_vars/all.yml` and uses `curl -fsS -o /dev/null -w '%{http_code}'`. It
retries for up to 120 seconds to allow ACME issuance.

## Failure modes

- ACME rate-limit hit during repeated bootstraps — surfaced by Traefik logs
  and by the smoke test failing on cert validation. Mitigation: persistent
  `acme.json` volume so re-bootstraps reuse cached certs.
- Domain DNS not pointing at any client node — smoke test fails with a clear
  message; the README documents the DNS prerequisite.
- Basic-auth password regenerated on re-run — avoided by writing the htpasswd
  hash into `secrets.yml` once.

## Files touched

```
ansible/group_vars/all.yml                        [edit]
ansible/roles/traefik/tasks/main.yml              [edit]
ansible/roles/traefik/templates/traefik.nomad.hcl.j2 [edit]
ansible/roles/sample_app/templates/whoami.nomad.hcl.j2 [edit]
bin/bootstrap                                     [edit]
tests/smoke/test_tls_ingress.sh                   [new]
README.md                                         [edit — DNS prerequisite]
terraform/terraform.tfvars.example                [edit — note]
```

## Dependencies

- Depends on `2026-04-26-cluster-security-baseline-design.md` only for the
  `secrets.yml` playbook scaffolding. Can be implemented in parallel; merge
  conflicts limited to `bin/bootstrap` and `group_vars/all.yml`.
