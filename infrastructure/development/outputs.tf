output "engine_ports" {
  description = "Port of every active engine, by engine name."
  value       = local.active_engines
}

output "engine_port_parameters" {
  description = "SSM parameter each active engine's port is published under, by engine name."
  value       = { for name, parameter in aws_ssm_parameter.engine_port : name => parameter.name }
}

output "ingress_rule_ids" {
  description = "Security group rule opening each engine to each tier, keyed <engine>-<tier>."
  value       = { for key, rule in module.engine_ingress : key => rule.id }
}
