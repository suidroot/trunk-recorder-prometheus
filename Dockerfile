FROM ubuntu:24.04 AS prometheus-cpp-builder
# Build prometheus-cpp and package it as a .deb.
# Uses plain ubuntu:24.04 (not the full trunk-recorder image) since only
# cmake and a C++ compiler are needed here.

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && \
    apt-get install --no-install-recommends -y \
        ca-certificates curl git cmake build-essential file zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# renovate: datasource=github-tags depName=jupp0r/prometheus-cpp
ARG PROMETHEUS_CPP_VERSION=v1.3.0

RUN git clone https://github.com/jupp0r/prometheus-cpp -b ${PROMETHEUS_CPP_VERSION} /tmp/prometheus-cpp && \
    cd /tmp/prometheus-cpp && \
    git submodule init && \
    git submodule update && \
    mkdir build && cd build && \
    cmake -DCPACK_GENERATOR=DEB -DBUILD_SHARED_LIBS=ON -DENABLE_PUSH=OFF -DENABLE_COMPRESSION=ON .. && \
    cmake --build . --target package --parallel $(nproc) && \
    mv prometheus-cpp_*.deb /prometheus-cpp.deb && \
    rm -rf /tmp/prometheus-cpp


FROM ghcr.io/robotastic/trunk-recorder:latest AS plugin-builder
# Compile the prometheus plugin against trunk-recorder's headers.
# All build tools stay in this stage and are never copied to the final image.

COPY --from=prometheus-cpp-builder /prometheus-cpp.deb /tmp/prometheus-cpp.deb

# Install prometheus-cpp runtime + all build-time dependencies.
# The apt/clone steps are intentionally placed before COPY . . so that
# Docker can cache this layer independently of source code changes.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && \
    apt-get install --no-install-recommends -y /tmp/prometheus-cpp.deb && \
    apt-get install --no-install-recommends --no-install-suggests -y \
        git \
        cmake \
        make \
        libssl-dev \
        build-essential \
        gnuradio-dev \
        gr-osmosdr \
        libuhd-dev \
        libcurl4-openssl-dev \
        libsndfile1-dev && \
    # Clone trunk-recorder to obtain dev headers that are absent from the
    # runtime image: lfsr/Eigen, json.hpp, and vendored op25_repeater headers.
    git clone --depth=1 https://github.com/robotastic/trunk-recorder /tmp/trunk-recorder && \
    mkdir -p /usr/local/include/op25_repeater/include/op25_repeater && \
    cp -r /tmp/trunk-recorder/lib/lfsr /usr/local/include/ && \
    cp /tmp/trunk-recorder/lib/json.hpp /usr/local/include/ && \
    # op25_repeater headers are copied to two paths:
    # - op25_repeater/*.h          for <op25_repeater/foo.h> style includes
    # - op25_repeater/include/...  for <op25_repeater/include/op25_repeater/foo.h> style includes
    cp /tmp/trunk-recorder/lib/op25_repeater/include/op25_repeater/*.h /usr/local/include/op25_repeater/ && \
    cp /tmp/trunk-recorder/lib/op25_repeater/include/op25_repeater/*.h /usr/local/include/op25_repeater/include/op25_repeater/ && \
    rm -rf /tmp/trunk-recorder /var/lib/apt/lists/*

WORKDIR /src/trunk-recorder-prometheus

COPY . .

WORKDIR /src/trunk-recorder-prometheus/build

# gnuradio-runtime.conf is temporarily moved aside because gnuradio reads it
# at cmake configure time and produces a spurious error in a build environment.
RUN mv /etc/gnuradio/conf.d/gnuradio-runtime.conf /tmp/gnuradio-runtime.conf && \
    cmake .. && make -j$(nproc) && make install && \
    mv /tmp/gnuradio-runtime.conf /etc/gnuradio/conf.d/gnuradio-runtime.conf


FROM ghcr.io/robotastic/trunk-recorder:latest
# Final runtime image. Only the compiled plugin .so and the prometheus-cpp
# runtime library are added; no build tools or source files are present.

COPY --from=prometheus-cpp-builder /prometheus-cpp.deb /tmp/prometheus-cpp.deb
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && \
    apt-get install --no-install-recommends -y /tmp/prometheus-cpp.deb && \
    rm -rf /var/lib/apt/lists/* /tmp/prometheus-cpp.deb

COPY --from=plugin-builder /usr/local/lib/trunk-recorder/prometheus_plugin.so \
                            /usr/local/lib/trunk-recorder/

WORKDIR /app
