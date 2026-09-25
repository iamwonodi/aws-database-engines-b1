# Working on this repository

This is a **blueprint**: many projects clone it. Never commit anything project-specific (repository names or IDs, account IDs, bucket names). Per-project values ship as `CHANGE_ME` and are set by `scripts/init-engines.sh`.

## Ground rules

- **Never run `terraform plan` or `terraform apply`**, or any AWS-mutating command, unless asked in that specific request. `terraform fmt`, `validate` and `test` are fine.
- Read the real files, and core's host scripts they feed (`modules/database/host/assets/update.sh`, `provision.sh`, `modules/platform/host-scripts/assets/deploy-lib.sh`), before proposing a change. Defects live in the seam between the two repositories.
- Ask before building. Classify review findings CRITICAL / HIGH / MEDIUM / LOW / OPTIONAL, say PASS when something is correct, and do not rewrite working code for style.
- Comments explain why, not what. Scripts are exercised against real inputs and their error paths before they are called done.

## Contracts with the other repositories

- **Core** publishes `/<project>/platform/config` (schema version 1), whose `buckets.deploy`, `database.update_document`, `ecr_registry_url`, `isolated.security_group_id` and `tiers.<tier>.security_group_id` this repository uses. Core's `engines-role` defines what this repository may do.
- **The database host** (core's `update.sh`) reads `database/registry.json` and `database/engines/<engine>/`. The registry rules and the reserved names (`DATA_ROOT`, `ENGINE_NAME`, `ENGINE_PORT`, `CORE_ROOT_SECRET_ARN`) are its; `ENGINE_IMAGE` is this repository's.
- **Core's provision.sh** finds an engine by Compose project `db-<engine>` and knows only `postgres`, `mysql` and `mongodb`, connecting as `postgres`, `root` and `admin`.
- **Services** read `/<project>/database/engines/<engine>/port`. Each engine is on its native port (5432, 3306, 27017), one engine per type shared by every service; `validate-engines.sh` requires the published host port to equal the engine's port.

## Checks before a commit

```bash
bash scripts/ci/validate-engines.sh database
bash scripts/ci/tests/run-all.sh
terraform fmt -recursive
(cd infrastructure/development && terraform init -backend=false && terraform validate && terraform test)
```

## Open items

- Nothing here has run against real AWS (core's `docs/first-real-run.md` gathers what to watch across every repository). Watch the first deploy for: `ec2:AuthorizeSecurityGroupIngress` with a referenced security group and tags under the engines role, the healthchecks passing inside `compose up --wait`, and MongoDB's first boot (its temporary init server can answer the healthcheck early).
- `infrastructure/development/.terraform.lock.hcl` is committed, locked for every platform; CI fails without it. Re-lock and commit after a provider change (docs/first-setup.md).
- Root password rotation is not propagated: the images read the administrator password only on first boot.
- Say **engine registry** (`registry.json`), **port registry** or **ECR registry**, never "the registry".
