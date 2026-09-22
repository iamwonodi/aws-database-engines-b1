# Database engines (development)

The **platforms team's** repository. It decides which database engines run on the development environment's EC2 database host, and who can reach them.

This is a **blueprint**: each project creates its own copy with GitHub's **Use this template** and runs `scripts/init-engines.sh`. It pairs with the core platform ([`aws-core-infra-b1`](https://github.com/iamwonodi/aws-core-infra-b1)), which owns the host, and with each service's infrastructure repository ([`aws-service-infra-b1`](https://github.com/iamwonodi/aws-service-infra-b1)), which provisions its own database on an engine published here.

Staging and production do not use this repository: they run a managed RDS instance that core creates.

## How it fits

```text
this repository                               core (development account)
─────────────────                             ──────────────────────────
database/registry.json   ──validate──┐
database/engines/<engine>/           │
                                     ▼
                   mirror image ──► ECR  engines/<engine>:<tag>-<arch>-<digest>
                   publish      ──► deploy bucket  database/engines/<engine>/   (first)
                                                   database/registry.json       (last)
                   send         ──► <project>-database-update ──► database host
                                                                   update.sh: compose up / stop
                   terraform    ──► isolated SG: engine port from the private and internal tiers
                                    SSM /<project>/database/engines/<engine>/port
                                                                   ▲
service infra repository ── reads the port, provisions its database ┘
```

Everything about the environment comes from core's platform contract, `/<project>/platform/config`. This repository never reads core's state.

## The engine registry

```json
{
  "postgres": { "port": 20001, "active": false },
  "mysql":    { "port": 20002, "active": false },
  "mongodb":  { "port": 20003, "active": false }
}
```

The blueprint ships all three engines **inactive**: a project opts in by setting `"active": true` and merging.

| Change | On the host | Port and parameter |
| --- | --- | --- |
| `"active": true` (or omitted) | started with `docker compose up --wait` as project `db-<engine>` | opened and published |
| `"active": false` | stopped with `docker compose stop`, data kept | closed and removed |
| entry removed | left running, untouched | closed and removed |

A database never stops because a file disappeared: only an explicit `"active": false` stops one. Nothing ever runs `down` or deletes data.

Ports are allocated from **20001–20099** and are unique across every engine, active or not, so an allocation never moves.

## An engine folder

```text
database/engines/<engine>/
  docker-compose.yaml   image: ${ENGINE_IMAGE}, env_file: .resolved/.env,
                        "${ENGINE_PORT}:<container port>",
                        ${DATA_ROOT}/${ENGINE_NAME}:<data directory>
  .env                  settings, and secrets as pointers only
  image.json            {"source": "postgres:17", "platform": "linux/amd64"}
```

| Name | Provided by | Meaning |
| --- | --- | --- |
| `ENGINE_IMAGE` | the publish step | the mirrored ECR image, appended to the published `.env` |
| `ENGINE_PORT` | the host | the port from the registry |
| `ENGINE_NAME` | the host | the folder name |
| `DATA_ROOT` | the host | the persistent data volume. Data anywhere else is refused |
| `CORE_ROOT_SECRET_ARN` | the host | the database administrator secret (`username`, `root_password`) |

These five names are reserved: an engine's `.env` may not set them.

Secrets are referenced, never written. The host resolves each pointer into a scratch file that is deleted after `compose up`:

```env
POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:root_password
```

`validate-engines.sh` refuses a literal value for any key containing `PASSWORD`, `SECRET`, `TOKEN` or `KEY`. That is why the `.env` files are committed.

The engine names `postgres`, `mysql` and `mongodb` are the ones core's provisioning script knows. It connects inside the container as `postgres`, as MySQL's `root` (restricted here to `localhost`), and as MongoDB's `admin`, so the compose files keep those users.

## Images

The database host has no internet path, and core refuses images from anywhere but this account's ECR. `mirror-images.sh` resolves each active engine's `image.json` source to a digest and copies it to `engines/<engine>:<tag>-<arch>-<first 12 of the digest>`, in a tag-immutable repository with scan-on-push.

A series tag such as `postgres:17` picks up upstream patch releases on the next deploy, and a new image restarts that engine. **To hold a version, pin an exact tag** in `image.json` (`"postgres:17.6"`).

`platform` must match the database host's architecture: `linux/amd64` for core's default `t3.medium`, `linux/arm64` for Graviton.

## Workflows

| Workflow | When | Does |
| --- | --- | --- |
| `tests.yml` | every pull request and push | validates the engines, rendering each compose file; shellcheck; script tests; fmt; lock file; `validate` and `test` |
| `plan.yml` | pull request | the Terraform plan (ports opening or closing), under `development-plan` |
| `deploy.yml` | merge to main, or manual | validate, plan, mirror, publish, update, apply, under `development` |

## Access

Core generates this repository's role (`modules/platform/engines-role`). It may:

- publish under `database/` in the deploy bucket;
- send only the database-update document, and only to the database host;
- write `/<project>/database/engines/*` and read the platform contract;
- change inbound rules on the isolated security group;
- push to ECR under `engines/`;
- keep its state under `platform/database-engines/`.

**IAM cannot limit which port or source a rule opens,** so this role can change any inbound rule on the tier where the databases live. Review pull requests here as carefully as core's, and give the `development` environment required reviewers (`--reviewers`).

## Setting up a copy

See [docs/first-setup.md](docs/first-setup.md). The decisions behind this design are in [docs/decisions.md](docs/decisions.md).

## Checks before a commit

```bash
bash scripts/ci/validate-engines.sh database
bash scripts/ci/tests/run-all.sh
terraform fmt -recursive
terraform -chdir=infrastructure/development init -backend=false
terraform -chdir=infrastructure/development validate
(cd infrastructure/development && terraform test)
```
