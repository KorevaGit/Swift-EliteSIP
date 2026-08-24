# Сборка панели.
#
# CGO выключен намеренно: драйвер SQLite — чистый Go (modernc.org/sqlite),
# поэтому бинарник получается статическим и не тянет за собой libc образа.
FROM golang:1.26-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/elitesip-panel ./cmd/elitesip-panel

FROM alpine:3.20

# ca-certificates нужны для выкладки в R2 по HTTPS. Без них панель поднимется
# и упадёт на первой выкладке — то есть ровно тогда, когда её ждут.
# wget — для проверки живости из compose.
RUN apk add --no-cache ca-certificates

RUN adduser -D -H -u 10001 elitesip
USER elitesip

COPY --from=build /out/elitesip-panel /usr/local/bin/elitesip-panel

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/elitesip-panel"]
CMD ["serve"]
