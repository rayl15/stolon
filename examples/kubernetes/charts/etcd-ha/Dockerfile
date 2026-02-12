# Build etcd with latest Go to fix CVE-2025-61732 (cgo code smuggling)
FROM golang:1.24.13-alpine AS builder

ARG ETCD_VERSION=v3.5.21

RUN apk add --no-cache git make bash

WORKDIR /build

RUN git clone --depth 1 --branch ${ETCD_VERSION} \
    https://github.com/etcd-io/etcd.git .

# Update golang.org/x/crypto to fix CVE-2025-47913
RUN cd server && go get golang.org/x/crypto@v0.43.0 && go mod tidy && \
    cd ../etcdctl && go get golang.org/x/crypto@v0.43.0 && go mod tidy && \
    cd ../etcdutl && go get golang.org/x/crypto@v0.43.0 && go mod tidy

# Build etcd binaries (etcd 3.5.x structure)
RUN cd server && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /etcd . && \
    cd ../etcdctl && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /etcdctl . && \
    cd ../etcdutl && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /etcdutl .

# Final minimal image
FROM alpine:3.21

LABEL maintainer="SourceFuse"
LABEL description="etcd - vulnerability free build with Go 1.24.13"

# Security: upgrade packages for CVE-2025-15467, CVE-2025-69419/20/21 (OpenSSL)
RUN apk upgrade --no-cache && \
    apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1000 etcd

COPY --from=builder /etcd /usr/local/bin/etcd
COPY --from=builder /etcdctl /usr/local/bin/etcdctl
COPY --from=builder /etcdutl /usr/local/bin/etcdutl

RUN mkdir -p /var/lib/etcd && chown -R etcd:etcd /var/lib/etcd

USER etcd

EXPOSE 2379 2380

ENTRYPOINT ["/usr/local/bin/etcd"]
