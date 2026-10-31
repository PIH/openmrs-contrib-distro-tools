# A distribution's seed image (.github/workflows/build-seeded-image.yml): a /seed directory holding an
# entry per service, named as `pihx <instance> initialize --from-image <image>` restores them. It
# is only copied from, never run.
FROM alpine:3.21
COPY openmrs-db.sql.gz openmrs.tar.gz /seed/
