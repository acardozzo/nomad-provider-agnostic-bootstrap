variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

variable "server_count" {
  type = number
}

variable "client_count" {
  type = number
}

variable "server_instance_type" {
  type = string
}

variable "client_instance_type" {
  type = string
}

variable "image" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "cluster_tags" {
  type = list(string)
}
