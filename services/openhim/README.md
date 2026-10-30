# openhim

The standard OpenHIM install: MongoDB, openhim-core and openhim-console. Settings are in
`openhim.env`; defaults are in [`env.defaults`](env.defaults). Mediators are services of their own
(for now [`openhim-advapacs-mediator`](../openhim-advapacs-mediator/)), and more than one can be
attached to the same OpenHIM; each requires `openhim`.

OpenHIM's MongoDB database is named `openhim` (it was `openhim-development` before TASKS-596). An
instance created before starts on an empty database: `openhim-setup` sets the admin password again
and each mediator registers and provisions its channels and clients on its next start, but the
transaction log, audit events, metrics and anything changed by hand in the console aren't carried
over. The old database stays in the `mongo-data` volume, to copy with `mongodump` / `mongorestore
--nsFrom 'openhim-development.*' --nsTo 'openhim.*'` or drop.

OpenHIM's clients authenticate with Basic auth or custom tokens; its JWT authentication is off,
since nothing uses it and it would otherwise accept a token signed with a shared secret for any
client.

Inside the instance's Docker network, OpenHIM and its mediators talk plain HTTP, including
openhim-core's admin API; TLS for access from outside is the reverse proxy's job. The service
publishes only what's used from outside, and its [`compose.yaml`](compose.yaml) says why each one is:

| Variable | Default | Published for |
|---|---|---|
| `OPENHIM_CONSOLE_HOST_PORT` | `9000` | the admin console |
| `OPENHIM_ADMIN_API_HOST_PORT` | `8081` | the admin API, which the console (running in the admin's browser) calls directly |
| `OPENHIM_ROUTER_HTTP_HOST_PORT` | `5001` | the router, for external systems calling a channel. A proxy in front should forward only those channels' paths: some channels are public |

Other variables: `OPENHIM_CORE_IMAGE_TAG`, `OPENHIM_CONSOLE_IMAGE_TAG` and `OPENHIM_MONGO_IMAGE_TAG`
(release tags, not `latest`, so an upgrade is a deliberate change to `env.defaults`, checked with
this setup), and `OPENHIM_USERNAME` / `OPENHIM_PASSWORD` (the admin login, which the mediators use
too; set the password in `openhim.env`).

Behind a proxy, tell the console where the browser finds the admin API, and set the console's own
address for links openhim-core generates. The defaults are for a browser on the same machine:

| Variable | Default |
|---|---|
| `OPENHIM_CONSOLE_API_PROTOCOL`, `OPENHIM_CONSOLE_API_HOST`, `OPENHIM_CONSOLE_API_PORT`, `OPENHIM_CONSOLE_API_PATH` | `http`, `localhost`, `OPENHIM_ADMIN_API_HOST_PORT`, empty |
| `OPENHIM_CONSOLE_URL` | `http://localhost:<OPENHIM_CONSOLE_HOST_PORT>` |

For example, with the proxy serving the console at `https://openhim.example.org` and forwarding
`/api` there to the admin API: `OPENHIM_CONSOLE_API_PROTOCOL=https`,
`OPENHIM_CONSOLE_API_HOST=openhim.example.org`, `OPENHIM_CONSOLE_API_PORT=443`,
`OPENHIM_CONSOLE_API_PATH=/api`, `OPENHIM_CONSOLE_URL=https://openhim.example.org`.

Logging in to the console needs that proxy, serving the admin API over HTTPS. openhim-core's session
cookie is Secure, and core trusts the proxy's `X-Forwarded-Proto` to know the request came in over
HTTPS. Caddy sends it by default; behind nginx, add `proxy_set_header X-Forwarded-Proto $scheme;`.
Without it, or with the browser going straight to the published port, every login fails, and
openhim-core logs "Cannot send secure cookie over unencrypted connection".

## The AdvaPACS mediator

`openhim-advapacs-mediator` carries radiology orders between OpenMRS and AdvaPACS. Its
[`env.defaults`](../openhim-advapacs-mediator/env.defaults) lists its variables; the secrets and
identifiers it has no default for are set in `openhim-advapacs-mediator.env`. It needs `OPENMRS_USERNAME`
and `OPENMRS_PASSWORD` (an OpenMRS account for the mediator), `ADVAPACS_CLIENT_ID` and
`ADVAPACS_CLIENT_SECRET`, `ADVAPACS_PATIENT_IDENTIFIER_SYSTEM`, and the inbound secret and client
password. An instance for Lesotho, with OpenHIM and the mediator, is created like this:

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci
export OPENHIM_PASSWORD=<pick-a-password>
export ADVAPACS_MEDIATOR_INBOUND_SECRET=<pick-a-secret>
export ADVAPACS_MEDIATOR_OPENHIM_INBOUND_CLIENT_PASSWORD=<pick-a-password>
export ADVAPACS_CLIENT_ID=<advapacs-client-id>
export ADVAPACS_CLIENT_SECRET=<advapacs-client-secret>
export OPENMRS_USERNAME=<username-for-mediator-access-to-openmrs>
export OPENMRS_PASSWORD=<password-for-mediator-access-to-openmrs>
export ADVAPACS_PATIENT_IDENTIFIER_SYSTEM="http://www.pih.org/identifiers/lesotho/emr-id"
openmrs-docker <name> create --services=openmrs-db,openmrs,openhim,openhim-advapacs-mediator
openmrs-docker <name> initialize --from-image partnersinhealth/lesotho-emr-seed-lesotho
openmrs-docker <name> start
```

`create` writes each value to the file of the service whose defaults or compose file name it.
