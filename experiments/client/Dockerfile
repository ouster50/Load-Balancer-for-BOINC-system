FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        boinc-client \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/boinc-experiment-client
RUN chmod +x /usr/local/bin/boinc-experiment-client

ENTRYPOINT ["/usr/local/bin/boinc-experiment-client"]
