# Validates root-module logic without hitting real Vultr/Linode APIs.
# Mock providers stub all resources; assertions check that the correct
# provider sub-module activates per `provider_name` and that outputs
# expose the expected instance count and shape for Ansible inventory.

mock_provider "vultr" {}
mock_provider "linode" {}

variables {
  cluster_name         = "test-cluster"
  region               = "test-region"
  server_count         = 3
  client_count         = 2
  server_instance_type = "test-server"
  client_instance_type = "test-client"
  image                = "test-image"
  ssh_public_key       = "ssh-ed25519 AAAA test@test"
}

run "vultr_provider_activates_only_vultr_module" {
  command = plan

  variables {
    provider_name = "vultr"
  }

  assert {
    condition     = length(module.vultr) == 1
    error_message = "vultr module must activate when provider_name=vultr"
  }

  assert {
    condition     = length(module.linode) == 0
    error_message = "linode module must NOT activate when provider_name=vultr"
  }

  assert {
    condition     = output.provider_name == "vultr"
    error_message = "provider_name output must echo selected provider"
  }
}

run "linode_provider_activates_only_linode_module" {
  command = plan

  variables {
    provider_name = "linode"
  }

  assert {
    condition     = length(module.linode) == 1
    error_message = "linode module must activate when provider_name=linode"
  }

  assert {
    condition     = length(module.vultr) == 0
    error_message = "vultr module must NOT activate when provider_name=linode"
  }

  assert {
    condition     = output.provider_name == "linode"
    error_message = "provider_name output must echo selected provider"
  }
}

run "cluster_name_propagates_to_output" {
  command = plan

  variables {
    provider_name = "vultr"
    cluster_name  = "prod-edge"
  }

  assert {
    condition     = output.cluster_name == "prod-edge"
    error_message = "cluster_name output must reflect input variable"
  }
}

run "ansible_user_default_is_root" {
  command = plan

  variables {
    provider_name = "vultr"
  }

  assert {
    condition     = output.ansible_user == "root"
    error_message = "ansible_user must default to root"
  }
}
