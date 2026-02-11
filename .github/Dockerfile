ARG PGVERSION=0
ARG GOSU_VERSION=1.17

#######
####### Build the stolon binaries
#######
FROM golang:1.24.13-bookworm AS builder

WORKDIR /stolon

# copy all the sources
COPY . .

RUN make

#######
####### Build gosu from source with latest Go (fixes CVE-2025-58183, CVE-2025-61729)
#######
FROM golang:1.24.13-bookworm AS gosu-builder

ARG GOSU_VERSION

RUN set -eux; \
    go install -ldflags='-s -w' github.com/tianon/gosu@${GOSU_VERSION}; \
    gosu nobody true

#######
####### Build the final image (Debian for pgBackRest support)
#######
FROM postgres:${PGVERSION}

# Security: Apply latest security patches (CVE-2025-15467, CVE-2025-69419-21)
# Install pgBackRest for 500GB+ incremental backups
# - Incremental/differential backups (only changed blocks)
# - Parallel backup and restore
# - Native S3/GCS/Azure support
# - Point-in-time recovery (PITR)
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends pgbackrest && \
    rm -rf /var/lib/apt/lists/*

# Create stolon user
RUN useradd -ms /bin/bash stolon

EXPOSE 5432

# Copy gosu built with latest Go (no stdlib vulnerabilities)
COPY --from=gosu-builder /go/bin/gosu /usr/local/bin/gosu

# Copy stolon binaries
COPY --from=builder /stolon/bin/ /usr/local/bin

RUN chmod +x /usr/local/bin/gosu /usr/local/bin/stolon-keeper /usr/local/bin/stolon-sentinel /usr/local/bin/stolon-proxy /usr/local/bin/stolonctl; \
    gosu nobody true
