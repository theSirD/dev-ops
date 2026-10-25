FROM node:24-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/mcp \
    && /opt/mcp/bin/pip install --no-cache-dir mcp-server-git==2026.10.19 \
    && npm install -g supergateway@4.2.0 @modelcontextprotocol/server-filesystem@2.0.0
ENV PATH="/opt/mcp/bin:${PATH}"
RUN git config --system --add safe.directory /data/repository
ENTRYPOINT ["supergateway"]
