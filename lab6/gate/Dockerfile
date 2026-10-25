# build from dev-ops/lab6: docker build -f gate/Dockerfile -t lab6.local/shop-gate:v1 .
FROM python:3.12-slim

ARG TARGETARCH
ARG HELM_VERSION=v3.17.3

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /tmp \
 && mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && apt-get purge -y curl && rm -rf /var/lib/apt/lists/* /tmp/linux-*

WORKDIR /app
COPY gate/gate.py .
COPY charts/shop /chart

ENV HOME=/tmp
USER 10001
CMD ["python", "gate.py"]
