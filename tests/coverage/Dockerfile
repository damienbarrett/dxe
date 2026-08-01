FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

ARG KCOV_COMMIT=a39874f938ce13f7a65f253120d1ec946b349ffe
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash binutils-dev build-essential ca-certificates cmake coreutils findutils git \
      libcurl4-openssl-dev libdw-dev libelf-dev libiberty-dev libssl-dev \
      libstdc++-12-dev python3 zlib1g-dev \
 && git clone --filter=blob:none https://github.com/SimonKagstrom/kcov.git /tmp/kcov \
 && git -C /tmp/kcov checkout "$KCOV_COMMIT" \
 && cmake -S /tmp/kcov -B /tmp/kcov/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /tmp/kcov/build --parallel 2 \
 && cmake --install /tmp/kcov/build \
 && rm -rf /tmp/kcov \
 && rm -rf /var/lib/apt/lists/*
