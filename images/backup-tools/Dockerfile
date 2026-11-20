# ubuntu:26.04, pinned by digest
ARG UBUNTU_IMAGE=ubuntu@sha256:0e73b71479e7bc5f006bca872e25c3cd680dc052a0116f90d63ae363537db0dd

# Downloads and verifies what the image adds from outside Ubuntu's archive, so curl and gnupg stay out of it.
FROM ${UBUNTU_IMAGE} AS fetch
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

# Oracle's MySQL apt repository signing key ("MySQL Release Engineering <mysql-build@oss.oracle.com>"). The
# fingerprint is the one the MySQL 8.4 Reference Manual gives in "Signature Checking Using GnuPG" (key ID
# B7B3B788A8D3785C), and the one keyserver.ubuntu.com serves; the build fails unless the file holds that one
# key.
ARG MYSQL_KEY_FINGERPRINT=BCA43417C3B485DD128EC6D4B7B3B788A8D3785C
RUN curl -fsSL -o /tmp/mysql.asc https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 \
 && gpg --show-keys --with-colons /tmp/mysql.asc \
      | awk -F: -v want="${MYSQL_KEY_FINGERPRINT}" \
          '$1 == "pub" { n++ } $1 == "fpr" && !fpr { fpr = $10 } END { exit !(n == 1 && fpr == want) }' \
 && gpg --dearmor -o /mysql.gpg /tmp/mysql.asc

# azcopy, pinned to a release tarball. Microsoft publishes no checksum, so the SHA-256 below was computed
# from the tarball downloaded from the GitHub release page.
ARG AZCOPY_VERSION=10.34.1
ARG AZCOPY_SHA256=a0021809e53f2b40705509626b8d44f2312fa8ef39deeb941fcffd35012bf6d1
RUN curl -fsSL -o /tmp/azcopy.tar.gz \
      "https://github.com/Azure/azure-storage-azcopy/releases/download/v${AZCOPY_VERSION}/azcopy_linux_amd64_${AZCOPY_VERSION}.tar.gz" \
 && echo "${AZCOPY_SHA256}  /tmp/azcopy.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/azcopy.tar.gz -C / --no-same-owner --strip-components=1 "azcopy_linux_amd64_${AZCOPY_VERSION}/azcopy"

# supercronic, pinned to a release binary. The SHA-1 is the one published in the GitHub release notes.
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA1=1692066e350a88ff4d7d6474fe3c7a6c41ec5e89
RUN curl -fsSL -o /supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1}  /supercronic" | sha1sum -c - \
 && chmod +x /supercronic

# MongoDB's database tools (mongodump, mongorestore), for openhim's MongoDB. The SHA-256 is the one MongoDB
# publishes for the release (https://downloads.mongodb.org/tools/db/release.json). Built for Ubuntu 24.04,
# which runs on 26.04 (the tools are Go binaries).
ARG MONGO_TOOLS_VERSION=100.20.1
ARG MONGO_TOOLS_SHA256=20f43dcaa37f5a4841ac5a91da685a488a5ebbd81113c018e25a6b544cc350ea
RUN curl -fsSL -o /tmp/mongo-tools.tgz \
      "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2404-x86_64-${MONGO_TOOLS_VERSION}.tgz" \
 && echo "${MONGO_TOOLS_SHA256}  /tmp/mongo-tools.tgz" | sha256sum -c - \
 && tar -xzf /tmp/mongo-tools.tgz -C / --no-same-owner --strip-components=2 \
      "mongodb-database-tools-ubuntu2404-x86_64-${MONGO_TOOLS_VERSION}/bin/mongodump" \
      "mongodb-database-tools-ubuntu2404-x86_64-${MONGO_TOOLS_VERSION}/bin/mongorestore"

# Microsoft's sqlcmd (go-sqlcmd), for sqlserver: one static binary, where mssql-tools18 needs Microsoft's
# apt repository, which has no Ubuntu 26.04. Microsoft publishes no checksum, so the SHA-256 below was
# computed from the tarball downloaded from the GitHub release page.
ARG SQLCMD_VERSION=v1.11.0
ARG SQLCMD_SHA256=2e41111d2e00782d50b9f8887bf603890af1e85e308708703e4ce27dc3c410e7
RUN apt-get update && apt-get install -y --no-install-recommends bzip2 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /tmp/sqlcmd.tar.bz2 \
      "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-amd64.tar.bz2" \
 && echo "${SQLCMD_SHA256}  /tmp/sqlcmd.tar.bz2" | sha256sum -c - \
 && tar -xjf /tmp/sqlcmd.tar.bz2 -C / --no-same-owner sqlcmd

FROM ${UBUNTU_IMAGE}

LABEL authors="Michael Seaton <mseaton@pih.org>"

# Tools for the backups service (services/backups). Holds tools only; the backup logic lives in this
# repo (services/backups/scripts/, each service's scripts/backup.sh) and is mounted into the container.
# amd64 only (platforms): Oracle publishes its MySQL apt repository for amd64 only. On PATH: bash, tar,
# 7z (7-Zip), mysqldump and mysql, sqlite3, mongodump and mongorestore, sqlcmd, jq, GNU coreutils
# (df/du/stat), flock (util-linux), azcopy and supercronic. tzdata supplies /usr/share/zoneinfo so TZ is
# honored by date and supercronic.
# Ubuntu 26.04 ships uutils' Rust coreutils as the default; coreutils-from-gnu switches back to GNU's, which
# the scripts were written and tested against (the swap removes an essential package, hence the flag).
# mysqldump is Oracle's MySQL 8.4 LTS client, from Oracle's apt repository (signed by the key above). It
# dumps MySQL 5.6, 5.7, 8.0 and 8.4 servers.
ARG MYSQL_CLIENT_VERSION=8.4.13-1ubuntu26.04
COPY --from=fetch /mysql.gpg /usr/share/keyrings/mysql.gpg
RUN apt-get update \
 && apt-get install -y --no-install-recommends --allow-remove-essential \
      coreutils-from-gnu coreutils-from-uutils- rust-coreutils- \
 && apt-get install -y --no-install-recommends ca-certificates 7zip jq sqlite3 tzdata \
 && echo "deb [signed-by=/usr/share/keyrings/mysql.gpg] https://repo.mysql.com/apt/ubuntu resolute mysql-8.4-lts" \
      > /etc/apt/sources.list.d/mysql.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends "mysql-community-client=${MYSQL_CLIENT_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /azcopy /supercronic /mongodump /mongorestore /sqlcmd /usr/local/bin/

CMD ["/bin/sh"]
