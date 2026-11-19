# build
FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/categorization ./cmd/categorization

# runtime: só o binário (sem shell, sem gerenciador de pacotes), usuário não-root
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/categorization /categorization
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s CMD ["/categorization", "-healthcheck"]
ENTRYPOINT ["/categorization"]
