# A worker is plain Debian plus four packages:
# Dyalog (from dyalog.com), unixODBC and the Postgres ODBC driver (from apt),
# and Stark + Jarvis (two source files from GitHub).
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget curl locales unixodbc odbc-postgresql \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ARG DYALOG_APL_VERSION=20.0.53963
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      arm64) deb="linux_64_${DYALOG_APL_VERSION}_unicode.aarch64.deb" ;; \
      amd64) deb="linux_64_${DYALOG_APL_VERSION}_unicode.x86_64.deb" ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    wget -qO "/tmp/$deb" "https://www.dyalog.com/uploads/php/download.dyalog.com/download.php?file=20.0%2F$deb"; \
    apt-get update; apt-get install -y --no-install-recommends "/tmp/$deb"; \
    rm -rf "/tmp/$deb" /var/lib/apt/lists/*

ARG STARK_VERSION=v0.2.4
ADD https://raw.githubusercontent.com/dyalog-labs/stark/${STARK_VERSION}/APLSource/Stark.aplc /opt/stark/Stark.aplc
ADD https://raw.githubusercontent.com/dyalog-labs/stark/${STARK_VERSION}/APLSource/Jarvis.aplc /opt/stark/Jarvis.aplc

COPY app/ /worker/app/
