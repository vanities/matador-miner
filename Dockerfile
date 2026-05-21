# Isolated BTX GPU solo-miner.
# Runs the open-source btxchain/btx node + CUDA MatMul PoW inside a container so
# the only things this unaudited code can touch are the GPU and a data volume
# you own. Installs ONLY the GPG-signed github.com/btxchain/btx release.
FROM nvidia/cuda:13.0.0-runtime-ubuntu24.04
# ^ CUDA 13 runtime for Blackwell (RTX 5090). The host needs a matching recent
#   NVIDIA driver + nvidia-container-toolkit. Bump this tag to match your driver.

ENV DEBIAN_FRONTEND=noninteractive

# Required tooling (fail loudly if unavailable).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git gnupg jq xz-utils python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Likely runtime libs for the release binaries (best-effort: a wrong package
# name here must not break the image, since some builds are statically linked).
RUN apt-get update && apt-get install -y --no-install-recommends \
      libsqlite3-0 libevent-2.1-7t64 libgomp1 ; rm -rf /var/lib/apt/lists/* || true

# faststart installer may import requests; harmless if it doesn't.
RUN pip3 install --no-cache-dir --break-system-packages requests || true

# Pin the source tree to the release tag — provides the faststart installer and
# the contrib/mining helpers we drive at runtime.
ARG RELEASE_TAG=v0.30.1
RUN git clone --depth 1 --branch "${RELEASE_TAG}" \
      https://github.com/btxchain/btx.git /opt/btx-src

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
