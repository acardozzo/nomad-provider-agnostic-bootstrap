locals {
  cluster_tags = [var.cluster_name, "nomad", "consul"]
}

module "vultr" {
  source = "./modules/providers/vultr"
  count  = var.provider_name == "vultr" ? 1 : 0

  cluster_name         = var.cluster_name
  region               = var.region
  server_count         = var.server_count
  client_count         = var.client_count
  server_instance_type = var.server_instance_type
  client_instance_type = var.client_instance_type
  image                = var.image
  ssh_public_key       = var.ssh_public_key
  vpc_cidr             = var.vpc_cidr
  cluster_tags         = local.cluster_tags
}

module "linode" {
  source = "./modules/providers/linode"
  count  = var.provider_name == "linode" ? 1 : 0

  cluster_name         = var.cluster_name
  region               = var.region
  server_count         = var.server_count
  client_count         = var.client_count
  server_instance_type = var.server_instance_type
  client_instance_type = var.client_instance_type
  image                = var.image
  ssh_public_key       = var.ssh_public_key
  vpc_cidr             = var.vpc_cidr
  cluster_tags         = local.cluster_tags
}

locals {
  instances = var.provider_name == "vultr" ? module.vultr[0].instances : module.linode[0].instances
}
