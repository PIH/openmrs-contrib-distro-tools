# What pihx runs in: the Docker CLI with the Compose plugin (docker:28-cli lacks it), Python with
# PyYAML for the pihx package, and bash for the service scripts and commands pihx runs.
FROM docker:28-cli
RUN apk add --no-cache python3 py3-yaml docker-cli-compose bash
