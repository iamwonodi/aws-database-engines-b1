# Decisions

| Decision | Why |
| --- | --- |
| The blueprint ships postgres, mysql and mongodb, all inactive | Core has provisioning for all three; each project opts into what it uses, and nothing runs (or costs memory on the host) by default |
| Ports come from 20001–20099, unique across every engine, active or not | An allocation must never move: services read the port, and a reactivated engine should come back where it was |
| Engine ports are opened from the private and internal tiers' security groups | Those are where services run; security-group references follow the fleets as they scale, where CIDRs would not |
| Ports open and close after the host has acted | A newly active engine is running before services can reach or discover it; a deactivated one has stopped before its port closes |
| Only active engines are mirrored and published; the engines prefix syncs with `--delete` | An inactive engine is never started, and the host never stops an engine because its folder vanished, so there is nothing to keep |
| `ENGINE_IMAGE` is appended to the published `.env` | The host passes compose only the engine's `.env` and four platform values; the ECR registry URL is per account, so it cannot be committed in a blueprint |
| Images are mirrored by digest, into tag-immutable repositories, tagged `<tag>-<arch>-<digest12>` | A tag then always means one image, an existing one is not copied again, and a change of architecture cannot reuse the wrong image |
| One platform per image, from `image.json` | The host has one architecture; copying every platform in an upstream index would multiply the pull and the ECR storage for nothing |
| MySQL root is restricted to `localhost` | provision.sh uses root only inside the container; the image's default (`%`) would offer it on the published port |
| The deploy re-plans at merge instead of applying the pull request's plan artifact | The plan depends only on `registry.json` and the platform contract, and the pull request shows the same plan; the configuration is too small to justify the artifact machinery service-infra needs |
| `validate-engines.sh` refuses literal passwords, secrets, tokens and keys | The `.env` files are committed; the check is what makes that safe |
