# Automation Checklist

This checklist tracks what is already automated in the bootstrap and what still needs work before it becomes a more hands-off platform.

## Fully Automated

- [x] Provider-selected infrastructure provisioning with Terraform
- [x] `3` Nomad servers and `2` clients
- [x] SSH key wiring
- [x] Vultr VPC creation
- [x] Vultr firewall creation
- [x] Vultr instance creation
- [x] Linode instance creation
- [x] Inventory generation from Terraform outputs
- [x] Docker installation via Ansible
- [x] Consul installation and configuration via Ansible
- [x] Nomad installation and configuration via Ansible
- [x] Traefik deployment as a Nomad job
- [x] Sample app deployment behind Traefik
- [x] One-command flow shape with `bin/apply`, `bin/bootstrap`, and `bin/destroy`

## Partially Automated

[-] Linode networking and firewall parity with Vultr
[-] Traefik production ingress features like TLS, DNS, and hardened middleware
[-] Generic Nomad app deployment pipeline beyond the sample app
[-] Secret injection for provider tokens and SSH key without manual operator setup
[-] Local Ansible validation in this environment

## Not Automated Yet

[ ] DNS records

[ ] Let's Encrypt / ACME certificates

[ ] Nomad ACL bootstrap

[ ] Consul ACL bootstrap

[ ] Vault integration

[ ] Autoscaling clients

[ ] Rolling updates / blue-green deploys

[ ] Monitoring and alerting

[ ] Backups and snapshots

[ ] Provider failover / multi-provider cluster strategy

[ ] Sample app domain routing by hostname

[ ] CI/CD for plan, apply, and bootstrap

[ ] Post-deploy smoke tests against live endpoints

[ ] System hardening such as fail2ban, tighter firewall rules, and OS patch policy

[ ] Service discovery conventions for real apps

[ ] Artifact and image build pipeline

## Best Next Upgrades

[ ] TLS and DNS so Traefik can serve real domains automatically
[ ] Nomad and Consul ACL bootstrap for a less open cluster
[ ] Linode parity for VPC, firewall, and interface automation
[ ] Reusable app deployment contract with Traefik tags, env vars, health checks, and rollout settings
[ ] Live verification for Nomad leader, Consul health, Traefik health, and `/whoami`
[ ] Autoscaling path for client nodes
