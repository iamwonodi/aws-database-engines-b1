# First setup

Core must already be applied in the development account. This repository serves development only: a project whose core does not run development (its `environments.json`) skips it.

## 1. Create the repository from the template

Use **Use this template** on GitHub, then clone your copy.

## 2. Initialise it

In Git Bash:

```bash
scripts/init-engines.sh --project acme --region af-south-1 --reviewers alice
```

This sets `terraform.tfvars` and `backend.tf`, creates the `development` and `development-plan` GitHub Environments, and prints three lines for core.

## 3. Let core create the role

In core, add the printed lines to `infrastructure/development/terraform.tfvars`:

```hcl
database_engines_repository          = "OWNER/REPOSITORY"
database_engines_repository_owner_id = "<owner id>"
database_engines_repository_id       = "<repository id>"
```

Open a pull request in core and let it apply. Then connect this repository to the role:

```bash
scripts/fetch-role-arn.sh --core OWNER/CORE-REPOSITORY
```

## 4. Commit the provider lock file

Every platform is locked, one platform per call so a dropped connection costs only that platform. In PowerShell:

```powershell
terraform -chdir=infrastructure/development init -backend=false
terraform -chdir=infrastructure/development providers lock -platform=windows_amd64
terraform -chdir=infrastructure/development providers lock -platform=linux_amd64
terraform -chdir=infrastructure/development providers lock -platform=darwin_amd64
terraform -chdir=infrastructure/development providers lock -platform=darwin_arm64
```

Commit `infrastructure/development/.terraform.lock.hcl` with the initialised files and open a pull request. `Tests` and `Plan` run on it; merging runs `Deploy`, which publishes the (still inactive) registry.

## 5. Activate an engine

Set `"active": true` for the engine in `database/registry.json`. Optionally pin an exact image tag in its `image.json`. Open a pull request: the plan shows the port opening from both tiers and the SSM parameter being created. Merge it.

Services in development can then provision a database on that engine.
