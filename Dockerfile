FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ttyd \
    bash \
    ca-certificates \
    curl \
    git \
    sudo \
    procps \
    iproute2 \
    iputils-ping \
    tini \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Enable passwordless sudo
RUN usermod -aG sudo ubuntu && \
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" \
    > /etc/sudoers.d/ubuntu && \
    chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu

WORKDIR /home/ubuntu

EXPOSE 7681

# tini runs as PID 1 and reaps orphaned processes (e.g. SDK daemons started in
# the background), so they don't linger as <defunct> zombies.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["ttyd", "--writable", "-i", "0.0.0.0", "-p", "7681", "bash", "-l"]
