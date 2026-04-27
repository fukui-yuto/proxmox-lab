FROM golang:1.22-alpine

WORKDIR /app
COPY go.mod main.go ./
RUN go build -o app . && ./app
