terraform {
  required_providers {
    vultr = {
      source = "vultr/vultr"
    }
  }
}

locals {
  server_labels = [for idx in range(var.server_count) : format("%s-server-%02d", var.cluster_name, idx + 1)]
  client_labels = [for idx in range(var.client_count) : format("%s-client-%02d", var.cluster_name, idx + 1)]
}

resource "vultr_ssh_key" "cluster" {
  name    = "${var.cluster_name}-ssh"
  ssh_key = var.ssh_public_key
}

resource "vultr_vpc" "cluster" {
  region         = var.region
  description    = "${var.cluster_name}-vpc"
  v4_subnet      = cidrhost(var.vpc_cidr, 0)
  v4_subnet_mask = tonumber(split("/", var.vpc_cidr)[1])
}

resource "vultr_firewall_group" "cluster" {
  description = "${var.cluster_name}-firewall"
}

resource "vultr_firewall_rule" "ssh" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
}

resource "vultr_firewall_rule" "nomad_ui" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "4646"
}

resource "vultr_firewall_rule" "traefik_http" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "80"
}

resource "vultr_firewall_rule" "traefik_https" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "443"
}

resource "vultr_firewall_rule" "traefik_dashboard" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "8080"
}

resource "vultr_firewall_rule" "cluster_internal_tcp" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "10.42.0.0"
  subnet_size       = 24
  port              = "1:65535"
}

resource "vultr_firewall_rule" "cluster_internal_udp" {
  firewall_group_id = vultr_firewall_group.cluster.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "10.42.0.0"
  subnet_size       = 24
  port              = "1:65535"
}

resource "vultr_instance" "servers" {
  count = var.server_count

  label             = local.server_labels[count.index]
  hostname          = local.server_labels[count.index]
  region            = var.region
  plan              = var.server_instance_type
  os_id             = 2284
  ssh_key_ids       = [vultr_ssh_key.cluster.id]
  firewall_group_id = vultr_firewall_group.cluster.id
  vpc_ids           = [vultr_vpc.cluster.id]
  enable_ipv6       = false
  tags              = concat(var.cluster_tags, ["server"])
}

resource "vultr_instance" "clients" {
  count = var.client_count

  label             = local.client_labels[count.index]
  hostname          = local.client_labels[count.index]
  region            = var.region
  plan              = var.client_instance_type
  os_id             = 2284
  ssh_key_ids       = [vultr_ssh_key.cluster.id]
  firewall_group_id = vultr_firewall_group.cluster.id
  vpc_ids           = [vultr_vpc.cluster.id]
  enable_ipv6       = false
  tags              = concat(var.cluster_tags, ["client"])
}

output "instances" {
  value = concat(
    [
      for instance in vultr_instance.servers : {
        name       = instance.hostname
        role       = "server"
        public_ip  = instance.main_ip
        private_ip = try(instance.vpc2_ips[0], "")
        provider   = "vultr"
      }
    ],
    [
      for instance in vultr_instance.clients : {
        name       = instance.hostname
        role       = "client"
        public_ip  = instance.main_ip
        private_ip = try(instance.vpc2_ips[0], "")
        provider   = "vultr"
      }
    ]
  )
}
