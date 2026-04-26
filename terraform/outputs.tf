output "instances" {
  description = "Normalized instance metadata used for Ansible inventory rendering."
  value       = local.instances
}

output "cluster_name" {
  value = var.cluster_name
}

output "provider_name" {
  value = var.provider_name
}

output "ansible_user" {
  value = var.ansible_user
}
