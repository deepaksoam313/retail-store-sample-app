# Build Stage
FROM public.ecr.aws/amazonlinux/amazonlinux:2023 AS build-env

# Minimal dependencies for Go build
RUN dnf --setopt=install_weak_deps=False install -q -y \
    git \
    golang \
    && \
    dnf clean all

RUN mkdir -p "${GOPATH}/src" "${GOPATH}/bin" /appsrc
WORKDIR /appsrc

# MODIFIED: Changed goproxy.io (failing with 502) to the stable Google proxy
ENV GOPROXY=https://proxy.golang.org,direct

# Optimization: Copy only dependencies first to leverage Docker layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source code and build
COPY . .
RUN go build -o main main.go

# Final Stage (Runtime)
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

ENV APPUSER=appuser
ENV APPUID=1000
ENV APPGID=1000

RUN dnf --setopt=install_weak_deps=False install -q -y \
    shadow-utils \
    && \
    dnf clean all

RUN useradd \
    --home "/app" \
    --create-home \
    --user-group \
    --uid "$APPUID" \
    "$APPUSER"

WORKDIR /app
USER appuser

# Copy the binary from the build environment
COPY --chown=appuser:appuser --from=build-env /appsrc/main /app/

# MODIFIED: Simplified to only copy what exists to prevent build failures
COPY ./ATTRIBUTION.md ./

ENV GIN_MODE=release

ENTRYPOINT ["/app/main"]