{% if cookiecutter.language == 'python' -%}
FROM python:3.12-slim

WORKDIR /app
COPY app.py .
{% if cookiecutter.packages -%}
RUN pip install --no-cache-dir {{ cookiecutter.packages }}
{% endif -%}
RUN python app.py
{% elif cookiecutter.language == 'go' -%}
FROM golang:1.22-alpine

WORKDIR /app
COPY go.mod main.go ./
RUN go build -o app . && ./app
{% elif cookiecutter.language == 'node' -%}
FROM node:22-slim

WORKDIR /app
COPY package.json index.js ./
{% if cookiecutter.packages -%}
RUN npm install {{ cookiecutter.packages }}
{% endif -%}
RUN node index.js
{% elif cookiecutter.language == 'shell' -%}
FROM alpine:3.20

WORKDIR /app
COPY script.sh .
RUN chmod +x script.sh
{% if cookiecutter.packages -%}
RUN apk add --no-cache {{ cookiecutter.packages }}
{% endif -%}
RUN ./script.sh
{% endif -%}
