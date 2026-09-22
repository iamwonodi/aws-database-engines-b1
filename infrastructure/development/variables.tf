variable "project_name" {
  type        = string
  description = "Project name. Must match the project the platform (core) was set up with."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-16 lowercase letters, digits or hyphens, starting with a letter. If it is still the CHANGE_ME placeholder, run scripts/init-engines.sh."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS Region of the development account. Keep it in sync with backend.tf (backend blocks cannot use variables); scripts/init-engines.sh sets both."

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like af-south-1. If it is still the CHANGE_ME placeholder, run scripts/init-engines.sh."
  }
}
