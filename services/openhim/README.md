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

MongoDB is 7.0 (it was 4.0, end-of-life since 2022, before TASKS-655). MongoDB 7.0 can't open a 4.0
data directory, so an instance created before fails to start `mongo-db` until its volume is replaced.
To start OpenHIM on an empty database (with the same losses as above):

```bash
pihx <name> stop
docker volume rm <name>_mongo-data
pihx <name> start    # creates the volume again
```

To keep the data instead, upgrade it one major version at a time (4.2, 4.4, 5.0, 6.0, 7.0, setting
`featureCompatibilityVersion` after each), or `mongodump` it with 4.0 and `mongorestore` it into 7.0.
MongoDB 5.0 and later need a CPU with AVX (`grep -c avx /proc/cpuinfo` is more than 0).

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

Other variables: the images, `OPENHIM_CORE_IMAGE_NAME` / `_TAG`, `OPENHIM_CONSOLE_IMAGE_NAME` / `_TAG`
and `OPENHIM_MONGO_IMAGE_NAME` / `_TAG` (release tags, not `latest`, so an upgrade is a deliberate
change to `env.defaults`, checked with this setup), and `OPENHIM_USERNAME` / `OPENHIM_PASSWORD` (the admin login, which the mediators use
too). `OPENHIM_PASSWORD` has no default: an instance that doesn't set it fails to start.

| Variable | Default | |
|---|---|---|
| `OPENHIM_MONGO_MEMORY_LIMIT`, `OPENHIM_CORE_MEMORY_LIMIT`, `OPENHIM_CONSOLE_MEMORY_LIMIT` | `1g`, `1g`, `128m` | the containers' memory limits |
| `OPENHIM_MONGO_CACHE_SIZE_GB` | `0.25` | MongoDB's WiredTiger cache. Left to itself MongoDB sizes it from the memory it sees, which can be the host's, so it's set; keep it well under `OPENHIM_MONGO_MEMORY_LIMIT` |

MongoDB, openhim-core, openhim-console and the mediator each have a healthcheck, so `pihx <name>
wait` waits for them.

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

## Mediators

Each mediator is its own service, which requires `openhim`. For now there's one,
[`openhim-advapacs-mediator`](../openhim-advapacs-mediator/README.md), which carries radiology orders
between OpenMRS and AdvaPACS.
