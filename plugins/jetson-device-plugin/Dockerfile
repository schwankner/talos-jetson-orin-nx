# Build stage — cross-compile for linux/arm64
FROM --platform=linux/arm64 golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -ldflags="-w -s" -trimpath -o jetson-device-plugin .

# Minimal runtime — just the binary
FROM scratch
COPY --from=builder /app/jetson-device-plugin /jetson-device-plugin
ENTRYPOINT ["/jetson-device-plugin"]
