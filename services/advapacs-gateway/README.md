# advapacs-gateway

AdvaPACS's on-premises gateway, from its
[`advahealthsolutions/advapacs-gateway`](https://hub.docker.com/r/advahealthsolutions/advapacs-gateway)
image ([AdvaPACS's install guide](https://docs.advapacs.com/getting-started/connect-modalities/install-the-gateway/docker)).
It receives studies from the site's modalities over DICOM (and HL7, if set up) and uploads them to
AdvaPACS, connecting out over HTTPS only. It doesn't need `openhim` or the mediator: the mediator
carries orders, the gateway carries images.

Create the gateway in AdvaPACS (Configuration > Gateways > +), which shows its region and access
key; the secret is shown only once. Settings are in `advapacs-gateway.env`.

| Variable | Default | |
|---|---|---|
| `ADVAPACS_GATEWAY_REGION` | must be set | the gateway's region |
| `ADVAPACS_GATEWAY_ACCESS_KEY_ID` | must be set | the gateway's access key ID |
| `ADVAPACS_GATEWAY_ACCESS_KEY_SECRET` | must be set | the gateway's access key secret |
| `ADVAPACS_GATEWAY_IMAGE_NAME`, `ADVAPACS_GATEWAY_IMAGE_TAG` | `advahealthsolutions/advapacs-gateway`, `1.22.1` | to upgrade, change the tag in `advapacs-gateway.env` and run `update` |

Everything else is configured in AdvaPACS, and the gateway picks it up within a few minutes of
starting, when it shows as Online:

- **Ports.** Each Local AE (Configuration > Local AEs) and each gateway HL7 inbound service has its
  own port, which the gateway opens. The gateway uses the host's network, so these are the host's
  ports: nothing is published, but the host's firewall must let the modalities reach them. Give
  modalities the host's IP address, with the Local AE's AE title and port, and check with a C-ECHO.
- **Modalities.** Each one is a Remote AE (Configuration > Remote AEs), whose AE title must match the
  modality's exactly, case included. Its worklist and query settings are there too.
- **Data directory.** Leave it at the default, `/opt/AdvaHealthSolutions/AdvaPACSGateway`: that's the
  `advapacs-gateway-data` volume, which holds received studies until they're uploaded.

AdvaPACS asks for 4 GB of memory (8 GB recommended) and 50 GB of disk (200 GB recommended) for the
gateway, and an accurate clock (NTP): its authentication fails if the host's clock drifts.

```bash
export ADVAPACS_GATEWAY_REGION=<region>
export ADVAPACS_GATEWAY_ACCESS_KEY_ID=<access-key-id>
export ADVAPACS_GATEWAY_ACCESS_KEY_SECRET=<access-key-secret>
pihx <name> add-service advapacs-gateway
pihx <name> start
```
