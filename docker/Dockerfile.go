# kit template — Go service image. Copy to docker/Dockerfile in the service repo.
#
#   docker build -f docker/Dockerfile --build-arg GO_VERSION=1.24.1 -t svc .
#
# STRICTNESS NOTES
#   - Two stages, always. The builder carries the Go toolchain and a writable
#     $GOPATH; the runtime does not. An image with a compiler in it is an image
#     with a supply chain in it.
#   - CGO_ENABLED=0 so the binary is static. That is what lets the final stage be
#     distroless/static instead of a debian with libc in it. If you need cgo
#     (sqlite, DNS resolution), switch the final stage to
#     gcr.io/distroless/base-debian12 and re-test before you ship it.
#   - The build context is the service root, so `COPY . .` sees go.mod. Set
#     working-dir in the CI caller if the module lives in a subdirectory.
#   - nonroot, not root: the distroless nonroot user is uid 65532. There is no
#     shell in this image, so a compromised process cannot curl and pipe.
ARG GO_VERSION=1.24

FROM golang:${GO_VERSION} AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOOS=linux
# go.mod/go.sum first: dependency layers cache until the manifests change.
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG SERVICE_NAME=service
RUN go build -trimpath -ldflags="-s -w" -o /out/service ./cmd/${SERVICE_NAME}

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=build /out/service /app/service
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app/service"]
