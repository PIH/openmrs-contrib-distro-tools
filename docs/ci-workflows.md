# CI workflows

Reusable GitHub Actions workflows that distro and module repos call, each from a thin caller
workflow.

## Build and release

`.github/workflows/verify.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn clean
verify` against the calling repo's root `pom.xml` on Java 8/temurin. A distro repo consumes it with
a thin caller:

```yaml
name: Verify PRs

on:
  pull_request:
  workflow_dispatch:

jobs:
  build:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/verify.yml@main
```

No secrets required.

`.github/workflows/release-to-sonatype.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn
release:prepare release:perform -Prelease` against the calling repo's root `pom.xml`. Requires the
calling repo to define a `release` Maven profile that GPG-signs artifacts, plus a few other things
the workflow silently depends on (see `openmrs-config-pihemr`'s root `pom.xml` for a reference that
satisfies all of these):

- **`maven-gpg-plugin` >= 3.2.0, configured with `<signer>bc</signer>`.** The workflow passes the
  signing key via the `MAVEN_GPG_KEY` env var, which only the Bouncy Castle signer reads — the
  plugin's default signer expects a populated GPG keyring instead, and versions before 3.2.0 don't
  support `MAVEN_GPG_KEY` at all.
- **`<scm>` must use an HTTPS connection URL** (e.g. `scm:git:https://github.com/ORG/REPO.git`), not
  SSH. `release:perform` re-clones the repo via this URL, and only HTTPS picks up the credential
  `actions/checkout` persists into `.git/config` — an SSH `scm:git:git@github.com:...` URL has no
  credential configured and the clone fails.
- **Publishing must use server id `sonatype-central`**, matching the `server-id:
  sonatype-central` configured in the workflow's `setup-java` step: the
  `central-publishing-maven-plugin`'s `<publishingServerId>`, plus a `distributionManagement`
  `<snapshotRepository>` with that id and url `https://central.sonatype.com/repository/maven-snapshots/`.
  The id can't be `central`: Maven 3.10+ ties that id to Maven Central and won't send its
  credentials to central.sonatype.com.

Optionally builds and pushes a Docker image of the released version too, the same way
`build-and-deploy-to-sonatype.yml` does for snapshots (below) — pass `image_name` to enable this;
omit it for module repos with no distro to build (e.g. `openmrs-module-pihcore`,
`openmrs-module-pihapps`). Since `release:perform` builds the release under `target/checkout` rather
than the working copy's own `target/`, the Docker context is
`target/checkout/distro/target/distro/web`, and the version tag is read from
`target/checkout/pom.xml` rather than the (by-then-bumped-to-the-next-SNAPSHOT) working copy.

`release:prepare` bumps the working copy to the next SNAPSHOT and pushes that commit, but never
deploys it — and that push doesn't trigger `build-and-deploy-to-sonatype.yml`'s `on: push` either,
since it's pushed with the default `GITHUB_TOKEN` (GitHub's own loop-prevention means
GITHUB_TOKEN-authored pushes never trigger other workflow runs). So this workflow deploys the next
snapshot itself as a final step (Maven and, if `image_name` is set, Docker), rather than depending
on that push to trigger anything.

A distro repo consumes it with a thin caller:

```yaml
name: Release new version

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/release-to-sonatype.yml@main
    with:
      image_name: partnersinhealth/pihemr
    secrets: inherit
```

`permissions: contents: write` is required because `release:prepare` pushes commits and a tag to the
default branch. In a reusable-workflow call, the effective token permissions are governed by the
caller — a called workflow's own `permissions:` block can only narrow, never widen — so this must be
declared here.

Requires `SONATYPE_USERNAME`, `SONATYPE_PASSWORD`, `SONATYPE_GPG_PASSPHRASE`, and
`SONATYPE_GPG_PRIVATE_KEY` secrets available to the caller (passed via `secrets: inherit`); also
`DOCKERHUB_PASSWORD` if `image_name` is set.

The workflow runs on Maven 3.9.16, installed by the `.github/actions/setup-maven` composite action,
rather than the runner image's Maven (setup-java installs only the JDK). Under Maven 3.10,
`central-publishing-maven-plugin` 0.11.0 leaves local-repository files (`maven-metadata-local.xml`,
`_remote.repositories`) in the release bundle, and the Central Portal rejects it ("Bundle has
content that does NOT have a .pom file"). Drop the step once a plugin release fixes this. Snapshot
deploys aren't affected, so `build-and-deploy-to-sonatype.yml` uses the runner's Maven.

If `release:prepare` pushed its tag but `release:perform` then failed, pass that tag as
`republish_existing_tag` to publish it without preparing a new release. The workflow then runs only
`release:perform`, from the tag, followed by the usual next-snapshot deploy. It is not a way to
choose the next release's version: the workflow fails straight away if the tag doesn't already
exist. A caller exposes it as a `workflow_dispatch` input:

```yaml
on:
  workflow_dispatch:
    inputs:
      republish_existing_tag:
        description: Leave empty for a normal release. Only to re-publish a tag that a failed release already pushed (release:prepare pushed the tag, release:perform failed) - runs release:perform alone, from that tag.
        required: false
        default: ''

jobs:
  release:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/release-to-sonatype.yml@main
    with:
      republish_existing_tag: ${{ inputs.republish_existing_tag }}
    secrets: inherit
```

`.github/workflows/release-to-openmrs-jfrog.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn
release:prepare release:perform` (no signing profile) against the calling repo's root `pom.xml`,
deploying to the OpenMRS JFrog `modules-pih`/`modules-pih-snapshots` repos instead of Sonatype
Central. Unlike `release-to-sonatype.yml`, there's no GPG signing step and no requirement that
dependencies be non-SNAPSHOT — JFrog doesn't enforce Central's "no SNAPSHOT dependencies in a
release" rule. Requires the calling repo's root `pom.xml` to satisfy:

- **`maven-release-plugin` configured with
  `<allowTimestampedSnapshots>true</allowTimestampedSnapshots>`.** Without this, `release:prepare`'s
  own snapshot-dependency check fails the build on any SNAPSHOT dependency (the usual reason to use
  this workflow over `release-to-sonatype.yml` in the first place).
- **`<scm>` must use an HTTPS connection URL** (e.g. `scm:git:https://github.com/ORG/REPO.git`), not
  SSH, for the same re-clone-during-`release:perform` reason as `release-to-sonatype.yml` above.
- **`distributionManagement`/publishing must use server id `openmrs-repo-modules-pih`**, matching
  the `server-id: openmrs-repo-modules-pih` configured in the workflow's `setup-java` step (see
  `openmrs-module-pihcore`'s root `pom.xml` for a reference).

Optionally builds and pushes a Docker image of the released version too, the same way
`build-and-deploy-to-openmrs-jfrog.yml` does for snapshots (below) — pass `image_name` to enable
this; omit it for module repos with no distro to build (e.g. `openmrs-module-pihcore`,
`openmrs-module-pihapps`). Since `release:perform` builds the release under `target/checkout` rather
than the working copy's own `target/`, the Docker context is
`target/checkout/distro/target/distro/web`, and the version tag is read from
`target/checkout/pom.xml` rather than the (by-then-bumped-to-the-next-SNAPSHOT) working copy.

`release:prepare` bumps the working copy to the next SNAPSHOT and pushes that commit, but never
deploys it — and that push doesn't trigger `build-and-deploy-to-openmrs-jfrog.yml`'s `on: push`
either, since it's pushed with the default `GITHUB_TOKEN` (GitHub's own loop-prevention means
GITHUB_TOKEN-authored pushes never trigger other workflow runs). So this workflow deploys the next
snapshot itself as a final step (Maven and, if `image_name` is set, Docker), rather than depending
on that push to trigger anything.

A distro repo consumes it with a thin caller:

```yaml
name: Release new version

on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/release-to-openmrs-jfrog.yml@main
    with:
      image_name: partnersinhealth/pihemr
    secrets: inherit
```

`permissions: contents: write` is required for the same reason as `release-to-sonatype.yml` above.

Requires `OPENMRS_MAVEN_USERNAME`, `OPENMRS_MAVEN_PASSWORD`, and `GHA_WRITE_TOKEN` secrets available
to the caller (passed via `secrets: inherit`); also `DOCKERHUB_PASSWORD` if `image_name` is set.

`.github/workflows/build-and-deploy-to-openmrs-jfrog.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs `mvn
deploy` against the calling repo's root `pom.xml` on every push, deploying SNAPSHOT builds to the
OpenMRS JFrog `modules-pih-snapshots` repo, then builds and pushes a Docker image of the result.
This is the JFrog counterpart to `build-and-deploy-to-sonatype.yml` (which deploys SNAPSHOTs to
Sonatype Central) — new callers should prefer this one, since mixing Sonatype for snapshots with
JFrog for releases (or vice versa) just to shuffle credentials between the two is not worth the
complexity; `build-and-deploy-to-sonatype.yml` remains only for repos that haven't migrated their
release workflow off `release-to-sonatype.yml` yet. Requires the same `distributionManagement`
server id (`openmrs-repo-modules-pih`) as `release-to-openmrs-jfrog.yml` above.

A distro repo consumes it with a thin caller:

```yaml
name: Build and deploy

on:
  push:
    branches: [master]
  workflow_dispatch:

jobs:
  build-and-publish:
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-and-deploy-to-openmrs-jfrog.yml@main
    with:
      image_name: partnersinhealth/pihemr
      maven_profiles: distro-zip # only if the repo defines this profile
    secrets: inherit
```

Requires `OPENMRS_MAVEN_USERNAME`, `OPENMRS_MAVEN_PASSWORD`, and `DOCKERHUB_PASSWORD` secrets
available to the caller (passed via `secrets: inherit`).

All four workflows above that build a Docker image (`build-and-deploy-to-sonatype.yml`,
`build-and-deploy-to-openmrs-jfrog.yml`, `release-to-sonatype.yml`, `release-to-openmrs-jfrog.yml`)
share the same QEMU/Buildx/login/build-push steps via the `.github/actions/build-and-push-docker`
composite action, so that logic only needs to change in one place. Similarly, all four also share
the same `mvn deploy` + version-extraction steps via `.github/actions/maven-deploy` — the two
snapshot workflows use it for their one deploy, and the two release workflows use it a second time,
after `release:prepare`/`release:perform`, to deploy the next development version (see above). Both
are internal implementation details of those workflows, not something a distro repo calls directly.

### Base image variants

Each of those four workflows can also push additional tags of `image_name` built from the same
distro on variants of the `openmrs/openmrs-core` base image — for example, on Java 8 to match
production servers, while `latest` and the plain version tag stay on the default (Java 17) base
image. Pass `image_variants`, one variant per line as `<tag suffix>=<base image variant>`; each is
pushed as `latest-<suffix>` and `<version>-<suffix>`. The variant replaces the variant part of the
base image tag the SDK chose, e.g. `amazoncorretto-8` turns `2.8.9` into `2.8.9-amazoncorretto-8`.
Leave it empty after the `=` to use the plain base image tag instead — useful when the distro itself
defaults to a variant (via `docker.image.javaVersion`). An instance switches to a variant by setting
its `OPENMRS_IMAGE_TAG` (e.g. `latest-java8`):

```yaml
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-and-deploy-to-openmrs-jfrog.yml@main
    with:
      image_name: partnersinhealth/zl-emr
      image_variants: |
        java8=amazoncorretto-8
        java21=amazoncorretto-21
```

This relies on the SDK generating a Dockerfile with the base image tag's version and variant as
separate build args (`ARG BASE_IMAGE_VERSION=...` and `ARG BASE_IMAGE_VARIANT=...`), added in
[SDK-404](https://openmrs.atlassian.net/browse/SDK-404); the build fails with an explicit error if
the Dockerfile doesn't have them. The SDK can only split the tag when the distro sets
`docker.image.openmrsVersion`/`docker.image.javaVersion` (or neither) — if it sets a full
`docker.image.tag`, that whole tag is the version and each variant is appended to it. Maven runs
only once — every tag is built from the same Docker context. The variants are built one after
another after the `latest` and version tags are pushed, and each is a full multi-arch build, so each
one adds noticeably to the job's run time.

## Seed image builds

`.github/workflows/build-seeded-image.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) — it builds a distro
from source, runs it, exports the database and data volume with `openmrs-utils backup-mysqldump` and
`backup-openmrs-data-directory`, packages them into a seed image, and pushes it. A distro repo
consumes it with a thin caller workflow, one job per site (no matrix — with this much of the logic
already shared, a matrix mostly just saves repeating `secrets: inherit`):

```yaml
name: Build seeded images
on:
  schedule:
    - cron: '0 2 * * *'
  workflow_dispatch:

jobs:
  kol-ci:
    if: github.repository_owner == 'PIH'
    concurrency:
      group: build-seeded-images-kol-ci-${{ github.ref }}
      cancel-in-progress: true
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/build-seeded-image.yml@main
    with:
      image_name: partnersinhealth/lesotho-emr
      pih_config: lesotho
    secrets: inherit
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | OpenMRS image, no tag |
| `pih_config` | Optional | PIH config profile to seed, for a distro that uses one. Also used (lowercased) as the instance name unless `instance_name` is set |
| `instance_name` | Optional | Instance/seed-name identifier. Defaults to `pih_config`, lowercased — required if the distro has no `pih_config` to default from |
| `seed_image_name` | Optional | Full seed image name, no tag. Defaults to `<image_name>-seed-<instance_name>` |

Requires a `DOCKERHUB_PASSWORD` secret available to the caller (passed via `secrets: inherit`).

## Smoke tests

`.github/workflows/execute-pihemr-smoke-tests.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) — it creates an
`openmrs-docker` instance, attaches the `openmrs-smoke-tests` service, initializes it from a site's
seed image (for fast startup), waits for OpenMRS to be ready, then runs the smoke-tests image
against it over the instance's own Compose network, uploads the results as a
`smoke-test-results-<instance>` artifact (Maven's build/report output plus Selenium screenshots),
and tears everything down. It validates the built image/config in isolation, not any persistent
deployed server — no external network access or secrets beyond Docker Hub credentials are required.
A distro repo consumes it with a thin caller workflow, one job per site:

```yaml
name: Smoke tests

on:
  workflow_dispatch:

jobs:
  kouka:
    if: github.repository_owner == 'PIH'
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/execute-pihemr-smoke-tests.yml@main
    with:
      image_name: partnersinhealth/pihliberia-emr
      instance_name: kouka
      pih_config: liberia,liberia-harper,liberia-harper-kouka
      seed_image_name: partnersinhealth/pihliberia-emr-seed-liberia
      suite: liberia
    secrets: inherit
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | OpenMRS image, no tag |
| `instance_name` | Required | Clean identifier for the `openmrs-docker` instance and artifact naming (e.g. the real CI server's own name, like `kouka` or `kgh-test`) — independent of `pih_config`, which may be a comma-separated chain that isn't a valid instance/image-tag name on its own |
| `pih_config` | Required | Full PIH config chain to test, matching what the site's real CI server actually runs (e.g. `liberia,liberia-harper,liberia-harper-kouka`) — check the site repo's own `<server>.env` file for the authoritative value, not just its `build-seeded-images.yml` base profile |
| `seed_image_name` | Required | Full seed image name, no tag — pass the exact value the corresponding `build-seeded-images.yml` job produces (with `pih_config` now potentially multi-value, there's no reliable way to derive this automatically) |
| `suite` | Required | Smoke-test suite passed to `execute-smoke-tests.sh`, independent of `pih_config` (e.g. `liberia`, `sierraleone`, `mexico`, `zlCentral`) |
| `admin_user_password` | Optional | Admin user password baked into this site's seed data. Defaults to the smoke-tests image's own default |
| `tools_ref` | Optional | Ref of `openmrs-contrib-distro-tools` to check out. Defaults to its default branch — only needed to validate a change to this workflow, or to `bin/openmrs-docker`/`docker/services`, from a branch before merging |

Requires a `DOCKERHUB_PASSWORD` secret available to the caller (passed via `secrets: inherit`).

### Running smoke tests locally

The `openmrs-smoke-tests` service is opt-in — it's not part of the default `openmrs-db,openmrs` set
an instance creates with, so attach it explicitly:

```bash
OPENMRS_IMAGE_NAME=partnersinhealth/pihliberia-emr \
OPENMRS_PIH_CONFIG=liberia \
SEED_IMAGE_NAME=partnersinhealth/pihliberia-emr-seed-liberia \
openmrs-docker create myinstance

openmrs-docker myinstance add-service openmrs-smoke-tests
openmrs-docker myinstance initialize
openmrs-docker myinstance start
openmrs-docker myinstance wait
openmrs-docker myinstance run-service openmrs-smoke-tests ./execute-smoke-tests.sh liberia
```

Run `wait` before `run-service`: it streams the logs and returns once OpenMRS's healthcheck
(`/openmrs/health/started`) passes, so the smoke tests don't start against a half-started OpenMRS.

| Variable | Default | Purpose |
|---|---|---|
| `SMOKE_TESTS_OUTPUT_DIR` | `./smoke-test-output` | Host directory bind-mounted onto the container's Maven `target/` (build output, failsafe/surefire reports) |
| `SMOKE_TESTS_SCREENSHOTS_DIR` | `./smoke-test-screenshots` | Host directory bind-mounted onto the container's Selenium screenshot directory |
| `SMOKE_TESTS_ADMIN_PASSWORD` | image default (`Admin123`) | Admin password baked into this site's seed data |
| `SMOKE_TESTS_IMAGE_NAME`, `SMOKE_TESTS_IMAGE_TAG` | `partnersinhealth/pihemr-smoke-tests`, `latest` | Smoke-tests image to run |

Once done, tear the instance down with `openmrs-docker myinstance destroy --force`.

## Deploys and PETL runs on self-hosted runners

Both run on a server's own self-hosted runner (`runner-label`), skip with a warning while
`/etc/puppet/build-disabled` exists there, or while the instance they're for is held
(`/etc/puppet/build-disabled-<instance>`), and keep their output on the host: it can contain secrets
or data, and the job runs in the calling repo's context, often a public one. A runner runs one job at
a time, so jobs for the same host queue whichever repo they come from.

- **`deploy-via-runner.yml`** (`runner-label`, `puppet-manifest`, `instances`, `host`, `run-etl`):
  `git pull` and `puppet-apply.sh <manifest>` in `/etc/puppet`. `instances` (`all` by default, `none`,
  or one instance's name) and `host` (default `true`) choose what puppet applies, with the `site`
  manifest only; an app's deploy passes its own instance and `host: false`. A deploy for a held instance skips entirely; one for
  `all` warns about held instances, which puppet skips. A running deploy is never cancelled; per
  repository and instance, only the newest pending deploy waits. For `openmrs_docker` instances,
  puppet runs `openmrs-docker <instance> update`. With `run-etl`, the legacy host-installed PETL
  (`/opt/petl/bin/execute-full.sh`).
- **`run-petl-via-runner.yml`** (`runner-label`, `instance`): runs PETL for an `openmrs_docker`
  instance, as `sudo -u <instance> /home/<instance>/bin/run-petl`. Puppet's
  `openmrs_docker::service::petl` installs that script and, with `ci_runner => true`, the one sudoers
  rule allowing it. The script runs `openmrs-docker <instance> run-service --pull petl`, which holds
  the instance's lock (a deploy waits for it). PETL's output, which may contain data, isn't in the
  job's log: it's in the instance's `petl` container log on the host, `docker logs <instance>-petl`
  ([PETL](services.md#petl)). The job
  fails when PETL does, so the author of the change that triggered it is notified.

An ETL project calls it after building its image:

```yaml
  run-petl-on-ces-ci:
    needs: build-and-publish
    concurrency:
      group: run-petl-on-ces-ci-${{ github.ref }}
      cancel-in-progress: false
    uses: PIH/openmrs-contrib-distro-tools/.github/workflows/run-petl-via-runner.yml@main
    with:
      runner-label: appclstr-01
      instance: ces-ci
      notify_ci_dashboard: true
    secrets: inherit
```

## Vulnerability scanning

`.github/workflows/scan-docker-image.yml` is a [reusable
workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) that runs
[Trivy](https://github.com/aquasecurity/trivy) against a published image and uploads the results as
SARIF to the calling repo's own Security tab (Code scanning alerts). It's report-only — a scan that
finds vulnerabilities never fails the caller's pipeline, only a scan-execution error (bad image ref,
registry pull failure, etc.) does. A distro repo consumes it as a follow-up job after its
build-and-push job:

```yaml
scan:
  needs: build-and-publish
  if: github.repository_owner == 'PIH'
  uses: PIH/openmrs-contrib-distro-tools/.github/workflows/scan-docker-image.yml@main
  with:
    image_name: partnersinhealth/lesotho-emr
  permissions:
    security-events: write
```

| Input | Required? | Purpose |
|---|---|---|
| `image_name` | Required | Docker Hub image name, no tag |
| `tag` | Optional | Tag to scan. Defaults to `latest` |

No secrets required — the images scanned here are public, so Trivy pulls them anonymously. The
calling job must grant `permissions: security-events: write` itself; a called reusable workflow's
`permissions:` block can only narrow what the caller grants, never widen it.

Findings only surface in the Security tab on **public** repos — that's a free GitHub feature there,
but requires a GitHub Advanced Security license on a private repo.
