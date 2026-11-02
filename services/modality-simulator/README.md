# modality-simulator

Fake CR, US and CT imaging rooms, for testing the order → worklist → images flow without real
equipment, from [PIH/modality-simulator](https://github.com/PIH/modality-simulator). Each room is a
station with its own AE title and its own tab in the console (`http://<host>:8095`). A station reads
the AdvaPACS gateway's DICOM worklist; click **Acquire** on its tab and it sends images stamped with
that entry's patient and accession number back to the gateway.

Its settings are in `modality-simulator-config/stations.yaml` in the instance directory, which you
create before adding the service (puppet writes it on the servers it manages). The directory holds
`stations.yaml`. The fields are in the simulator's
[README](https://github.com/PIH/modality-simulator#the-stations-file); for example:

```yaml
gateway:
  ae: PIH_KOL-CI_GW     # the gateway's Local AE title in AdvaPACS
stations:
  - {name: X-ray, calling_ae: KOL-CI_CR, modalities: [CR]}
  - {name: Ultrasound, calling_ae: KOL-CI_US, modalities: [US]}
```

Other settings are in `modality-simulator.env`:

| Variable | Default | |
|---|---|---|
| `MODALITY_SIMULATOR_CONFIG_DIR` | `./modality-simulator-config` | holds `stations.yaml`; relative to the instance directory |
| `MODALITY_SIMULATOR_HOST_PORT` | `8095` | the console's port on the host, or `<ip>:<port>` to publish it on one address only. The console has no login, so on a shared server give it a private address (e.g. the host's VPN address), unlike the other services' ports |
| `MODALITY_SIMULATOR_MEMORY_LIMIT` | `512m` | the container's memory limit |
| `MODALITY_SIMULATOR_IMAGE_NAME`, `MODALITY_SIMULATOR_IMAGE_TAG` | `partnersinhealth/modality-simulator`, `latest` | |

In AdvaPACS, add each station as a Remote AE (Configuration > Remote AEs) whose AE title exactly
matches its `calling_ae`, and let it query the worklist. Until then, its tab says the gateway
rejected the association.

It doesn't depend on the `advapacs-gateway` service, so it also works with a gateway elsewhere
(set `gateway.host` in `stations.yaml`). It sends images it generates: the image's `/images`
directory (DICOM files to send instead) isn't mounted, as CI hasn't needed it. After changing
`stations.yaml`, restart the simulator (`pihx <name> restart modality-simulator`).

```bash
pihx <name> add-service modality-simulator
pihx <name> start
```
