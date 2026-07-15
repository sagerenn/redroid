# AOSP / redroid host builder (adapted from remote-android/redroid-doc android-builder-docker).
# Used only to compile redroid; final runtime images do not inherit from this.
# Must work on both amd64 and arm64 CI runners (ubuntu-24.04 / ubuntu-24.04-arm).
FROM ubuntu:22.04

ARG userid=1000
ARG groupid=1000
ARG username=builder

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\n' > /etc/apt/apt.conf.d/80-retries; \
    for i in 1 2 3 4 5; do apt-get update && break || sleep $((i * 5)); done; \
    pkgs=" \
      git-core gnupg flex bison build-essential zip curl zlib1g-dev \
      libncurses5 libncurses5-dev \
      x11proto-core-dev libx11-dev libgl1-mesa-dev libxml2-utils \
      xsltproc unzip fontconfig rsync sudo ca-certificates \
      python3 python3-pip python3-dev python-is-python3 \
      pkg-config ninja-build gettext \
      procps openssh-client \
    "; \
    arch="$(dpkg --print-architecture)"; \
    if [ "$arch" = "amd64" ]; then \
      pkgs="$pkgs gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev lib32z1-dev"; \
    fi; \
    apt-get install -y --no-install-recommends $pkgs \
    && pip3 install --no-cache-dir mako meson \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g "$groupid" "$username" \
    && useradd -m -u "$userid" -g "$groupid" "$username" \
    && echo "$username ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && echo "$username" >/root/username \
    && echo "$username:$username" | chpasswd && adduser "$username" sudo

ENV HOME=/home/$username \
    USER=$username \
    PATH=/src/.repo/repo:/src/prebuilts/jdk/jdk8/linux-x86/bin:$PATH

WORKDIR /src
USER $username
ENTRYPOINT ["/bin/bash", "-lc"]
