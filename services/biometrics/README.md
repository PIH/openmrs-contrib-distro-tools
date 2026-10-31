# biometrics

The [pih-biometrics](https://github.com/PIH/pih-biometrics) fingerprint server: it stores
fingerprint templates and enrolls and matches them for OpenMRS (pihcore). Scanning happens on the
user's workstation, through the fingerprint client there; this server never sees a scanner. It
publishes nothing: OpenMRS reaches it on the instance's network, so set these two runtime properties
in `openmrs.env` (pihcore reads them in lowercase from the release with UHM-9581 on):

```bash
OMRS_EXTRA_pihcore_biometrics_subjecturl='http://biometrics:9000/subject'
OMRS_EXTRA_pihcore_biometrics_matchurl='http://biometrics:9000/match'
```

Settings are in `biometrics.env`.

| Variable | Default | |
|---|---|---|
| `BIOMETRICS_LICENSE_BASE64` | must be set | the Neurotechnology license file, base64-encoded: `base64 -w0 <file>.lic` |
| `BIOMETRICS_MATCHING_THRESHOLD`, `BIOMETRICS_MATCHING_SPEED`, `BIOMETRICS_TEMPLATE_SIZE` | `72`, `LOW`, `LARGE` (the app's own defaults) | speed: `LOW`, `MEDIUM` or `HIGH`; size: `COMPACT`, `SMALL`, `MEDIUM` or `LARGE` |
| `BIOMETRICS_IMAGE_NAME`, `BIOMETRICS_IMAGE_TAG` | `ghcr.io/pih/pih-biometrics`, `latest` | `latest` is the newest master build; releases are tagged with their version |

The image is private (it contains Neurotechnology's libraries), so `pull` needs the host's Docker
credentials for `ghcr.io`, for the user that runs `pihx`. The license is an internet
license: it checks in with Neurotechnology over outbound HTTP (port 80) every few minutes, and runs on
one machine at a time. The container keeps the same machine identity when it's recreated because its
hostname is fixed and the identity Neurotechnology's library keeps in `/var/tmp` is on the
`biometrics-licensing` volume. Losing that volume, or moving the instance to another host, makes it a
new machine: it can't get the license until the old activation expires (about 30–40 minutes).
The `biometrics-data` volume holds the fingerprint templates, which are patient data: back it up
wherever the instance's data matters. To check the server can enroll and match:
`docker exec <name>-biometrics pih-biometrics-selftest`.

```bash
export BIOMETRICS_LICENSE_BASE64=$(base64 -w0 <file>.lic)
pihx <name> add-service biometrics
pihx <name> start
```
