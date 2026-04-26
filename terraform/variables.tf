variable "provider_name" {
  description = "Provider to use for cluster provisioning."
  type        = string

  validation {
    condition     = contains(["vultr", "linode"], var.provider_name)
    error_message = "provider_name must be either vultr or linode."
  }
}

variable "cluster_name" {
  description = "Short cluster label used in resource names."
  type        = string
  default     = "nomad-cluster"
}

variable "region" {
  description = "Provider region code, such as sao for Vultr or br-gru for Linode."
  type        = string
}

variable "server_count" {
  description = "Number of Nomad server nodes."
  type        = number
  default     = 3
}

variable "client_count" {
  description = "Number of Nomad client nodes."
  type        = number
  default     = 2
}

variable "server_instance_type" {
  description = "Provider-specific instance plan for Nomad servers."
  type        = string
}

variable "client_instance_type" {
  description = "Provider-specific instance plan for Nomad clients."
  type        = string
}

variable "image" {
  description = "Provider-specific image identifier."
  type        = string
}

variable "ssh_public_key" {
  description = "Public SSH key material."
  type        = string
}

variable "ansible_user" {
  description = "SSH user Ansible should use."
  type        = string
  default     = "root"
}

variable "vpc_cidr" {
  description = "Private subnet for providers that support explicit VPC creation."
  type        = string
  default     = "10.42.0.0/24"
}
