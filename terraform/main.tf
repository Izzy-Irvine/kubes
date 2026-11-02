terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "clowder/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "ap-southeast-2"
  allowed_account_ids = ["472750445632"]

  default_tags {
    tags = {
      Project   = "kubes"
      ManagedBy = "terraform"
    }
  }
}

module "backend" {
  source = "./modules/backend"
}

resource "aws_iam_openid_connect_provider" "clowder" {
  url = "https://oidc.izzy.kiwi"

  client_id_list = ["sts.amazonaws.com"]
}

output "state_bucket_name" {
  value = module.backend.state_bucket_name
}

output "github_actions_role_arn" {
  value = module.backend.github_actions_role_arn
}
