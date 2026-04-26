# `app` role — generic Nomad+Traefik app deployment

Deploys any Docker image as a Nomad service registered in Consul Catalog, routed
by Traefik on a hostname rule, with health checks and canary rolling updates.

## Required vars (per invocation)

```yaml
app_name: "myapp"             # nomad job + consul service name
app_image: "ghcr.io/org/myapp:1.2.3"
app_host: "myapp.example.com" # Traefik Host(...) rule
```

## Optional vars (with defaults)

```yaml
app_count: 2
app_path_prefix: ""           # if set, routes Host(...) && PathPrefix(...) and strips prefix
app_container_port: 8080
app_cpu: 200                  # MHz
app_memory: 128               # MB
app_health_path: "/"          # http health check
app_env: {}                   # map of env vars
app_tls: true                 # use websecure entrypoint with le resolver
```

## Usage

```yaml
- hosts: servers[0]
  become: true
  roles:
    - role: app
      vars:
        app_name: api
        app_image: ghcr.io/org/api:v0.4.1
        app_host: api.example.com
        app_count: 3
        app_env:
          DATABASE_URL: "postgres://..."
```
