ARG PGVERSION=0
ARG ARCHITECTURE=amd64

#######
####### Build the stolon binaries
#######
FROM golang:1.24-bookworm AS builder

WORKDIR /stolon

# copy all the sources
COPY . .

RUN make

#######
####### Build the final image
#######
FROM postgres:${PGVERSION}

# Install gosu for running commands as stolon user (required by K8s manifests)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gosu; \
    rm -rf /var/lib/apt/lists/*; \
    gosu nobody true

RUN useradd -ms /bin/bash stolon

EXPOSE 5432

COPY --from=builder /stolon/bin/ /usr/local/bin

RUN chmod +x /usr/local/bin/stolon-keeper /usr/local/bin/stolon-sentinel /usr/local/bin/stolon-proxy /usr/local/bin/stolonctl
