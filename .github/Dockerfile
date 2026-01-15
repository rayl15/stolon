ARG PGVERSION=0
ARG ARCHITECTURE=amd64
ARG GOSU_VERSION=1.17

#######
####### Build the stolon binaries
#######
FROM golang:1.24-bookworm AS builder

WORKDIR /stolon

# copy all the sources
COPY . .

RUN make

#######
####### Build gosu from source with latest Go (fixes CVE-2025-58183, CVE-2025-61729)
#######
FROM golang:1.24-bookworm AS gosu-builder

ARG GOSU_VERSION
ARG ARCHITECTURE

RUN set -eux; \
    go install -ldflags='-s -w' github.com/tianon/gosu@${GOSU_VERSION}; \
    gosu nobody true

#######
####### Build the final image (Alpine for minimal CVEs)
#######
FROM postgres:${PGVERSION}-alpine

# Install su-exec (Alpine's gosu equivalent) and create stolon user
RUN apk add --no-cache su-exec && \
    adduser -D -s /bin/sh stolon

EXPOSE 5432

# Copy gosu built with latest Go (no stdlib vulnerabilities)
COPY --from=gosu-builder /go/bin/gosu /usr/local/bin/gosu

COPY --from=builder /stolon/bin/ /usr/local/bin

RUN chmod +x /usr/local/bin/gosu /usr/local/bin/stolon-keeper /usr/local/bin/stolon-sentinel /usr/local/bin/stolon-proxy /usr/local/bin/stolonctl; \
    gosu nobody true
