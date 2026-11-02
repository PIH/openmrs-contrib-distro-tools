# openhim-advapacs-mediator

The AdvaPACS radiology-order mediator, from
[PIH/openhim-advapacs-mediator](https://github.com/PIH/openhim-advapacs-mediator) (its README has how it
works). It carries radiology orders from OpenMRS to AdvaPACS, and AdvaPACS's results (imaging studies
and reports) back. It requires [`openhim`](../openhim/): it registers with openhim-core, which routes
its traffic, and it provisions its own channels and client there on every start.

The service keeps its name, `openhim-advapacs-mediator`, everywhere: its directory, its env file and
puppet's `openmrs_docker::service::openhim_advapacs_mediator`. Its variables are all prefixed
`ADVAPACS_MEDIATOR_`, so none of them looks like another service's (e.g. openmrs's `OPENMRS_*`);
[`compose.yaml`](compose.yaml) passes them to the mediator under the names it reads. Don't rename
the service: the mediator's `mediatorConfig.json`, in its image, routes its channel to the host
`openhim-advapacs-mediator`.

Settings are in `openhim-advapacs-mediator.env`. These have no default, so the instance must set them:

| Variable | |
|---|---|
| `ADVAPACS_MEDIATOR_OPENMRS_USERNAME`, `ADVAPACS_MEDIATOR_OPENMRS_PASSWORD` | the OpenMRS account the mediator uses with OpenMRS's FHIR API |
| `ADVAPACS_MEDIATOR_ADVAPACS_CLIENT_ID`, `ADVAPACS_MEDIATOR_ADVAPACS_CLIENT_SECRET` | its AdvaPACS API client |
| `ADVAPACS_MEDIATOR_PATIENT_IDENTIFIER_SYSTEM` | the FHIR identifier system of the patient identifier sent to AdvaPACS |
| `ADVAPACS_MEDIATOR_INBOUND_SECRET` | the shared secret on the order requests the mediator's poller sends it through OpenHIM |
| `ADVAPACS_MEDIATOR_OPENHIM_INBOUND_CLIENT_PASSWORD` | the password of the OpenHIM client the poller uses |

It also uses `openhim`'s `OPENHIM_USERNAME` / `OPENHIM_PASSWORD` to register. The others have
defaults ([`env.defaults`](env.defaults)):

| Variable | Default | |
|---|---|---|
| `ADVAPACS_MEDIATOR_OPENMRS_BASE_URL`, `ADVAPACS_MEDIATOR_OPENMRS_FHIR_PATH` | `http://openmrs:8080/openmrs`, `/ws/fhir2/R4` | the instance's own OpenMRS; for one on the host, `http://host.docker.internal:8080/openmrs` |
| `ADVAPACS_MEDIATOR_ADVAPACS_BASE_URL` | `https://usa1.api.integration.advapacs.com/fhir/R5` | AdvaPACS's FHIR API: the real host, which the mediator sets as its OpenHIM channel's route |
| `ADVAPACS_MEDIATOR_PRACTITIONER_IDENTIFIER_SYSTEM` | empty | the FHIR identifier system of the ordering provider's identifier |
| `ADVAPACS_MEDIATOR_SITE_MAP` | empty | the AdvaPACS Site each order is sent to: `<visit-location-uuid>=<site-identifier>,...`, mapping OpenMRS Visit Locations to the identifiers of AdvaPACS Sites (see below) |
| `ADVAPACS_MEDIATOR_ORGANIZATION` | empty | the identifier of the AdvaPACS Organisation the Sites in `ADVAPACS_MEDIATOR_SITE_MAP` must belong to |
| `ADVAPACS_MEDIATOR_ADVAPACS_WEBHOOK_SECRET` | empty | the bearer token for AdvaPACS's result webhook. The mediator doesn't serve the webhook yet; set it, and make it required in `compose.yaml`, when it does |
| `ADVAPACS_MEDIATOR_ORDER_INGESTION_MODE`, `ADVAPACS_MEDIATOR_ORDER_POLL_INTERVAL_MS` | `poll`, `15000` | how it gets orders from OpenMRS |
| `ADVAPACS_MEDIATOR_OPENHIM_INBOUND_CLIENT_ID` | `openmrs` | the OpenHIM client the poller uses |
| `ADVAPACS_MEDIATOR_LOG_LEVEL` | `info` | |
| `ADVAPACS_MEDIATOR_MEMORY_LIMIT` | `256m` | the container's memory limit |
| `ADVAPACS_MEDIATOR_IMAGE_NAME`, `ADVAPACS_MEDIATOR_IMAGE_TAG` | `partnersinhealth/openhim-advapacs-mediator`, `latest` | |

With `ADVAPACS_MEDIATOR_SITE_MAP` empty, orders are sent without a Site. Once it's set, an order
whose Site can't be determined fails in OpenHIM rather than being sent without one. The Site
identifiers differ between AdvaPACS setups (e.g. `LS-DM-BOTS` on demo, `LS-BOTS` on production).

Its healthcheck is its own `/health` endpoint, so `pihx <name> wait` waits for it. It publishes no
port: openhim-core reaches it on the instance's network.

An instance for Lesotho, with OpenHIM and the mediator, is created like this:

```bash
export OPENMRS_IMAGE_NAME=partnersinhealth/lesotho-emr
export OPENMRS_PIH_CONFIG=lesotho,lesotho-kol-ci
export OPENHIM_PASSWORD=<pick-a-password>
export ADVAPACS_MEDIATOR_INBOUND_SECRET=<pick-a-secret>
export ADVAPACS_MEDIATOR_OPENHIM_INBOUND_CLIENT_PASSWORD=<pick-a-password>
export ADVAPACS_MEDIATOR_OPENMRS_USERNAME=<username-for-mediator-access-to-openmrs>
export ADVAPACS_MEDIATOR_OPENMRS_PASSWORD=<password-for-mediator-access-to-openmrs>
export ADVAPACS_MEDIATOR_ADVAPACS_CLIENT_ID=<advapacs-client-id>
export ADVAPACS_MEDIATOR_ADVAPACS_CLIENT_SECRET=<advapacs-client-secret>
export ADVAPACS_MEDIATOR_PATIENT_IDENTIFIER_SYSTEM="http://www.pih.org/identifiers/lesotho/emr-id"
pihx <name> create --services=openmrs-db,openmrs,openhim,openhim-advapacs-mediator
pihx <name> initialize --from-image partnersinhealth/lesotho-emr-seed-lesotho
pihx <name> start
```

`create` writes each value to the file of the service whose defaults or compose file name it.
