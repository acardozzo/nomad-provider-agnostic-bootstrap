terraform {
  required_providers {
    linode = {
      source = "linode/linode"
    }
  }
}

locals {
  server_labels = [for idx in range(var.server_count) : format("%s-server-%02d", var.cluster_name, idx + 1)]
  client_labels = [for idx in range(var.client_count) : format("%s-client-%02d", var.cluster_name, idx + 1)]
}

resource "linode_sshkey" "cluster" {
  label   = "${var.cluster_name}-ssh"
  ssh_key = var.ssh_public_key
}

resource "linode_instance" "servers" {
  count = var.server_count

  label           = local.server_labels[count.index]
  region          = var.region
  type            = var.server_instance_type
  image           = var.image
  authorized_keys = [trimspace(var.ssh_public_key)]
  private_ip      = true
  tags            = concat(var.cluster_tags, ["server"])
}

resource "linode_instance" "clients" {
  count = var.client_count

  label           = local.client_labels[count.index]
  region          = var.region
  type            = var.client_instance_type
  image           = var.image
  authorized_keys = [trimspace(var.ssh_public_key)]
  private_ip      = true
  tags            = concat(var.cluster_tags, ["client"])
}

output "instances" {
  value = concat(
    [
      for instance in linode_instance.servers : {
        name       = instance.label
        role       = "server"
        public_ip  = try(instance.ip_address, "")
        private_ip = try(instance.private_ip_address, "")
        provider   = "linode"
      }
    ],
    [
      for instance in linode_instance.clients : {
        name       = instance.label
        role       = "client"
        public_ip  = try(instance.ip_address, "")
        private_ip = try(instance.private_ip_address, "")
        provider   = "linode"
      }
    ]
  )
}
