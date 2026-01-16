# Build postgres_exporter with latest Go to eliminate vulnerabilities
FROM golang:1.24.11-alpine AS builder

ARG POSTGRES_EXPORTER_VERSION=v0.18.1

RUN apk add --no-cache git make

WORKDIR /build

RUN git clone --depth 1 --branch ${POSTGRES_EXPORTER_VERSION} \
    https://github.com/prometheus-community/postgres_exporter.git .

# Update vulnerable dependencies
RUN go get golang.org/x/crypto@v0.45.0 && \
    go mod tidy

# Build with CGO disabled for static binary
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w -X main.Version=${POSTGRES_EXPORTER_VERSION}" \
    -o /postgres_exporter ./cmd/postgres_exporter

# Final minimal image
FROM scratch

LABEL maintainer="SourceFuse"
LABEL description="PostgreSQL Prometheus Exporter - vulnerability free build"
LABEL version="0.18.1"

COPY --from=builder /postgres_exporter /postgres_exporter
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

USER 65534:65534

EXPOSE 9187

ENTRYPOINT ["/postgres_exporter"]
