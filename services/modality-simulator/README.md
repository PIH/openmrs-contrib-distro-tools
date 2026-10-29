# modality-simulator

A fake CR, US and CT imaging room, for testing the order → worklist → images flow without real
equipment, from [PIH/modality-simulator](https://github.com/PIH/modality-simulator). It reads the
AdvaPACS gateway's DICOM worklist; click **Acquire** in its console (`http://<host>:8095`) and it
sends images stamped with that entry's patient and accession number back to the gateway. Settings
are in `modality-simulator.env`.

| Variable | Default | |
|---|---|---|
| `MODALITY_SIMULATOR_GATEWAY_AE` | must be set | the gateway's Local AE title in AdvaPACS |
| `MODALITY_SIMULATOR_GATEWAY_HOST`, `MODALITY_SIMULATOR_GATEWAY_PORT` | `host.docker.internal`, `11112` | where the gateway listens: its Local AE's port, on this host by default |
| `MODALITY_SIMULATOR_CALLING_AE` | `SIM_MODALITY` | the simulator's AE title |
| `MODALITY_SIMULATOR_MODALITIES` | `CR,US,CT` | which worklist entries it shows |
| `MODALITY_SIMULATOR_STATION_AE_FILTER` | empty | only entries scheduled for this station AE |
| `MODALITY_SIMULATOR_INSTITUTION` | `OpenMRS Modality Simulator` | written into every image |
| `MODALITY_SIMULATOR_AUTO_ACQUIRE`, `MODALITY_SIMULATOR_POLL_SECONDS` | `false`, `30` | acquire every new entry on each poll, without clicking |
| `MODALITY_SIMULATOR_HOST_PORT` | `8095` | the console's port on the host |
| `MODALITY_SIMULATOR_IMAGE_DIR` | `./modality-simulator-images` | DICOM files to send instead of generated images; relative to the instance directory |
| `MODALITY_SIMULATOR_IMAGE_NAME`, `MODALITY_SIMULATOR_IMAGE_TAG` | `partnersinhealth/modality-simulator`, `latest` | |

In AdvaPACS, add the simulator as a Remote AE (Configuration > Remote AEs) whose AE title exactly
matches `MODALITY_SIMULATOR_CALLING_AE`, and let it query the worklist. Until then, its console
says the gateway rejected the association.

It doesn't depend on the `advapacs-gateway` service, so it also works with a gateway elsewhere
(set `MODALITY_SIMULATOR_GATEWAY_HOST`). With no files in its image directory it generates
images; any files you add there must be de-identified.

```bash
export MODALITY_SIMULATOR_GATEWAY_AE=PIH_KOL-CI_GW
pihx <name> add-service modality-simulator
pihx <name> start
```
