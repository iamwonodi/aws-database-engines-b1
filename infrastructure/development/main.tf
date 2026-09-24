# ------------------------------------------------------------------------------
# DATABASE ENGINE PORTS
#
# For every ACTIVE engine in database/registry.json:
#
#   - its port is opened on the isolated tier's security group, from each tier
#     whose services may connect to it (the shared fleets' security groups) and
#     from the team's own tools (core's team-tools group, a database GUI), and
#   - its port is published at /<project>/database/engines/<engine>/port, which
#     is where services read it (docs/platform-contract.md in core).
#
# An engine that becomes inactive loses both. Starting and stopping the engines
# themselves is the database host's job (scripts/ci/send-update.sh); this only
# decides who can reach them.
#
# Everything about the environment comes from the platform contract, never from
# core's state.
# ------------------------------------------------------------------------------

data "aws_ssm_parameter" "platform" {
  name = "/${var.project_name}/platform/config"
}

locals {
  platform = jsondecode(nonsensitive(data.aws_ssm_parameter.platform.value))

  # The same file the pipeline publishes, so what is open always matches what
  # runs. scripts/ci/validate-engines.sh has already checked it in CI.
  registry = jsondecode(file("${path.module}/../../database/registry.json"))

  # "active" defaults to true, as on the database host.
  active_engines = {
    for name, entry in local.registry : name => entry.port
    if try(entry.active, true)
  }

  # The shared fleets' security groups: where the services that connect to the
  # engines run. A tier without one (a dedicated environment) contributes none.
  tier_security_groups = {
    for tier, config in try(local.platform.tiers, {}) : tier => config.security_group_id
    if try(config.security_group_id, null) != null
  }

  # And the team's own tools (a database GUI), which run on hosts of their own
  # wearing core's team-tools group. A contract from before core published it
  # simply adds none.
  source_security_groups = merge(
    local.tier_security_groups,
    try(local.platform.tools.security_group_id, null) == null ? {} : { tools = local.platform.tools.security_group_id },
  )

  ingress_rules = {
    for pair in setproduct(keys(local.active_engines), keys(local.source_security_groups)) :
    "${pair[0]}-${pair[1]}" => {
      engine = pair[0]
      tier   = pair[1]
      port   = local.active_engines[pair[0]]
    }
  }
}

resource "terraform_data" "contract" {
  lifecycle {
    precondition {
      condition     = try(local.platform.schema_version, null) == 1
      error_message = "This repository was written for platform contract version 1; core publishes version ${try(local.platform.schema_version, "unknown")}."
    }

    precondition {
      condition     = try(local.platform.hosting_model, null) == "shared"
      error_message = "Database engines run only on the EC2 database host of a shared environment (development)."
    }

    precondition {
      condition     = try(local.platform.isolated.security_group_id, null) != null
      error_message = "The platform contract publishes no isolated security group to open the engine ports on."
    }

    precondition {
      condition     = length(local.tier_security_groups) > 0
      error_message = "The platform contract publishes no tier security group to allow the engine ports from."
    }
  }
}

module "engine_ingress" {
  source   = "git::https://github.com/iamwonodi/terraform-aws-sg-ingress-rule.git?ref=v1.2.0"
  for_each = local.ingress_rules

  security_group_id            = local.platform.isolated.security_group_id
  referenced_security_group_id = local.source_security_groups[each.value.tier]

  description = each.value.tier == "tools" ? "${each.value.engine} database engine from the team's tools" : "${each.value.engine} database engine from the ${each.value.tier} tier"

  ip_protocol = "tcp"
  from_port   = each.value.port
  to_port     = each.value.port

  tags = {
    Name   = "${var.project_name}-development-${each.value.engine}-from-${each.value.tier}"
    Engine = each.value.engine
  }

  depends_on = [terraform_data.contract]
}

# Where services read the port. Core's engines role may write only under
# /<project>/database/engines/.
resource "aws_ssm_parameter" "engine_port" {
  for_each = local.active_engines

  name        = "/${var.project_name}/database/engines/${each.key}/port"
  description = "Host port of the ${each.key} database engine on the database host."
  type        = "String"
  value       = tostring(each.value)

  tags = {
    Engine = each.key
  }

  depends_on = [terraform_data.contract]
}
