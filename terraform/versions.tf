terraform {
  required_version = ">= 1.5.0"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.23"
    }

    linode = {
      source  = "linode/linode"
      version = "~> 3.11"
    }
  }
}

provider "vultr" {}

provider "linode" {}
