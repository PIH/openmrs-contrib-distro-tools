#!/bin/sh
set -e
mkdir -p /target/data /target/db-init
tar xzf /seed/data.tar.gz -C /target/data
cp /seed/dump.sql.gz /target/db-init/dump.sql.gz
