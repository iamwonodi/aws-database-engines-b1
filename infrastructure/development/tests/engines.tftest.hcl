# Run with: terraform init -backend=false && terraform test   (from infrastructure/development)
# No AWS access: the provider is mocked and the platform contract is supplied here.
# The engine registry is the committed database/registry.json.

mock_provider "aws" {
  override_data {
    target = data.aws_ssm_parameter.platform
    values = {
      value = <<-JSON
        {
          "schema_version": 1,
          "hosting_model": "shared",
          "isolated": { "security_group_id": "sg-0iso" },
          "tiers": {
            "private":  { "security_group_id": "sg-0priv", "alb_security_group_id": "sg-0privalb" },
            "internal": { "security_group_id": "sg-0int",  "alb_security_group_id": "sg-0intalb" }
          }
        }
      JSON
    }
  }
}

variables {
  project_name = "acme"
  aws_region   = "af-south-1"
}

run "the_blueprint_opens_nothing_until_an_engine_is_activated" {
  command = plan

  assert {
    condition     = length(output.engine_ports) == 0 && length(module.engine_ingress) == 0 && length(aws_ssm_parameter.engine_port) == 0
    error_message = "the blueprint ships every engine inactive, so no port may be opened or published"
  }

  assert {
    condition     = length(local.registry) == 3
    error_message = "the blueprint registers postgres, mysql and mongodb"
  }

  assert {
    condition     = local.source_security_groups == { private = "sg-0priv", internal = "sg-0int" }
    error_message = "engines are reachable from the shared fleets' security groups"
  }
}

run "a_newer_contract_is_refused" {
  command = plan

  override_data {
    target = data.aws_ssm_parameter.platform
    values = {
      value = "{\"schema_version\": 2, \"hosting_model\": \"shared\", \"isolated\": {\"security_group_id\": \"sg-0iso\"}, \"tiers\": {\"private\": {\"security_group_id\": \"sg-0priv\"}}}"
    }
  }

  expect_failures = [terraform_data.contract]
}

run "a_dedicated_environment_is_refused" {
  command = plan

  override_data {
    target = data.aws_ssm_parameter.platform
    values = {
      value = "{\"schema_version\": 1, \"hosting_model\": \"dedicated\", \"isolated\": {\"security_group_id\": \"sg-0iso\"}, \"tiers\": {\"private\": {\"security_group_id\": null}}}"
    }
  }

  expect_failures = [terraform_data.contract]
}

run "a_contract_without_tier_security_groups_is_refused" {
  command = plan

  override_data {
    target = data.aws_ssm_parameter.platform
    values = {
      value = "{\"schema_version\": 1, \"hosting_model\": \"shared\", \"isolated\": {\"security_group_id\": \"sg-0iso\"}, \"tiers\": {}}"
    }
  }

  expect_failures = [terraform_data.contract]
}
