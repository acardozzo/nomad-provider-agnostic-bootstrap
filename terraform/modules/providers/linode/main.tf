terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = ">= 2.20"
    }
  }
}

locals {
  server_labels = [for idx in range(var.server_count) : format("%s-server-%02d", var.cluster_name, idx + 1)]
  client_labels = [for idx in range(var.client_count) : format("%s-client-%02d", var.cluster_name, idx + 1)]
}

resource "linode_sshkey" "cluster" {
  label   = "${var.cluster_name}-ssh"
  ssh_key = trimspace(var.ssh_public_key)
}

resource "linode_vpc" "cluster" {
  label       = replace(var.cluster_name, "_", "-")
  region      = var.region
  description = "${var.cluster_name} cluster VPC"
}

resource "linode_vpc_subnet" "cluster" {
  vpc_id = linode_vpc.cluster.id
  label  = "${replace(var.cluster_name, "_", "-")}-subnet"
  ipv4   = var.vpc_cidr
}

resource "linode_firewall" "cluster" {
  label = "${replace(var.cluster_name, "_", "-")}-fw"

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "http"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "nomad-ui"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "4646"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "cluster-internal-tcp"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "1-65535"
    ipv4     = [var.vpc_cidr]
  }

  inbound {
    label    = "cluster-internal-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "1-65535"
    ipv4     = [var.vpc_cidr]
  }

  linodes = concat(
    [for i in linode_instance.servers : i.id],
    [for i in linode_instance.clients : i.id],
  )
}

resource "linode_instance" "servers" {
  count = var.server_count

  label           = local.server_labels[count.index]
  region          = var.region
  type            = var.server_instance_type
  image           = var.image
  authorized_keys = [trimspace(var.ssh_public_key)]
  tags            = concat(var.cluster_tags, ["server"])

  interface {
    purpose = "public"
    primary = true
  }

  interface {
    purpose   = "vpc"
    subnet_id = linode_vpc_subnet.cluster.id
    ipv4 {
      vpc = cidrhost(var.vpc_cidr, count.index + 10)
    }
  }
}

resource "linode_instance" "clients" {
  count = var.client_count

  label           = local.client_labels[count.index]
  region          = var.region
  type            = var.client_instance_type
  image           = var.image
  authorized_keys = [trimspace(var.ssh_public_key)]
  tags            = concat(var.cluster_tags, ["client"])

  interface {
    purpose = "public"
    primary = true
  }

  interface {
    purpose   = "vpc"
    subnet_id = linode_vpc_subnet.cluster.id
    ipv4 {
      vpc = cidrhost(var.vpc_cidr, count.index + 50)
    }
  }
}

output "instances" {
  value = concat(
    [
      for idx, instance in linode_instance.servers : {
        name       = instance.label
        role       = "server"
        public_ip  = try(instance.ip_address, "")
        private_ip = cidrhost(var.vpc_cidr, idx + 10)
        provider   = "linode"
      }
    ],
    [
      for idx, instance in linode_instance.clients : {
        name       = instance.label
        role       = "client"
        public_ip  = try(instance.ip_address, "")
        private_ip = cidrhost(var.vpc_cidr, idx + 50)
        provider   = "linode"
      }
    ]
  )
}
