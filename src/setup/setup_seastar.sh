#!/bin/bash
# Seastar build on AWS Ubuntu 22.04
# Run AFTER setup_all.sh completes (DPDK 24.11 + igb_uio must already be installed)
# Takes ~25-35 min
set -e
LOG() { echo "[$(date +%H:%M:%S)] $*"; }
export DEBIAN_FRONTEND=noninteractive

LOG "=== Installing Seastar deps ==="
apt-get install -y -qq \
  cmake ninja-build pkg-config stow \
  libboost-all-dev libyaml-cpp-dev libhwloc-dev \
  libcrypto++-dev libfmt-dev liblz4-dev libsctp-dev \
  libgnutls28-dev libprotobuf-dev protobuf-compiler \
  python3-jinja2 ragel libnl-3-dev libnl-route-3-dev \
  2>&1 | tail -3

# Install newer CMake (Seastar needs 3.23+, Ubuntu 22.04 has 3.22)
pip3 install cmake --quiet 2>/dev/null || true
CMAKE=$(which cmake3 2>/dev/null || which cmake)
$CMAKE --version | head -1

LOG "=== Cloning Seastar ==="
cd /opt && rm -rf seastar
git clone https://github.com/scylladb/seastar --depth=1 -q

cd /opt/seastar

# Patch cooking_recipe.cmake to disable MLX5 drivers (not present on ENA instances)
sed -i 's|-Ddisable_drivers="net/softnic,net/bonding"|-Ddisable_drivers="net/softnic,net/bonding,net/mlx4,net/mlx5,common/mlx5,compress/mlx5,regex/mlx5,vdpa/mlx5"|' cooking_recipe.cmake

# Point Seastar at the system DPDK installed by setup_all.sh
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}

LOG "=== Configuring Seastar (with DPDK) ==="
./configure.py \
  --mode=release \
  --enable-dpdk \
  --cflags="-march=native" \
  --prefix=/opt/seastar-install 2>&1 | tail -10

ls build/release/build.ninja && LOG "build.ninja generated OK" || {
  LOG "configure.py failed — falling back to cmake"
  mkdir -p build/release
  cd build/release
  $CMAKE ../.. \
    -DCMAKE_BUILD_TYPE=Release \
    -DSeastar_DPDK=ON \
    -DCMAKE_INSTALL_PREFIX=/opt/seastar-install \
    -GNinja 2>&1 | tail -10
  cd /opt/seastar
}

LOG "=== Building Seastar library (~15 min) ==="
ninja -C build/release seastar -j$(nproc) 2>&1 | tail -10
LOG "libseastar.a: $(ls -lh build/release/libseastar.a 2>/dev/null)"

LOG "=== Building Seastar echo app ==="
# Find and build echo apps
ninja -C build/release -j$(nproc) 2>&1 | grep -E "echo|Linking|error" | head -20 || true

# Try common Seastar echo app locations
ECHO_BIN=$(find build/release -name "*echo*" -type f -executable 2>/dev/null | head -1)
if [ -n "$ECHO_BIN" ]; then
    cp $ECHO_BIN /usr/local/bin/seastar-echo
    LOG "Seastar echo: /usr/local/bin/seastar-echo"
else
    LOG "Building custom Seastar echo server..."
    cat > /tmp/seastar_echo.cc << 'CCEOF'
#include <seastar/core/app-template.hh>
#include <seastar/core/reactor.hh>
#include <seastar/core/future.hh>
#include <seastar/net/api.hh>
#include <seastar/net/inet_address.hh>
#include <iostream>

using namespace seastar;
using namespace net;

int main(int argc, char** argv) {
    app_template app;
    app.add_options()
        ("port", boost::program_options::value<uint16_t>()->default_value(11115), "UDP port")
        ("ip", boost::program_options::value<std::string>()->default_value("0.0.0.0"), "Bind IP");

    return app.run(argc, argv, [&] {
        auto& opts = app.configuration();
        uint16_t port = opts["port"].as<uint16_t>();
        std::string ip = opts["ip"].as<std::string>();

        return do_with(make_udp_channel(ipv4_addr{ip, port}), [](udp_channel& channel) {
            return keep_doing([&channel] {
                return channel.receive().then([&channel](udp_datagram dgram) {
                    return channel.send(dgram.get_src(), std::move(dgram.get_data()));
                });
            });
        });
    });
}
CCEOF

    # Build with seastar + DPDK
    SEASTAR_PC=$(find /opt/seastar/build/release -name 'seastar.pc' 2>/dev/null | head -1)
    DPDK_FLAGS=$(pkg-config --cflags --libs libdpdk 2>/dev/null || echo "")
    if [ -n "$SEASTAR_PC" ]; then
        SEASTAR_FLAGS=$(pkg-config --cflags --libs "$SEASTAR_PC" 2>/dev/null)
    else
        SEASTAR_FLAGS="-lseastar $(pkg-config --cflags --libs fmt gnutls yaml-cpp lz4 2>/dev/null) -lboost_program_options"
    fi
    g++ -std=c++20 -O2 /tmp/seastar_echo.cc \
        -I/opt/seastar -I/opt/seastar/build/release/gen \
        -L/opt/seastar/build/release \
        $SEASTAR_FLAGS $DPDK_FLAGS \
        -ldl -lnuma -lpthread \
        -o /usr/local/bin/seastar-echo 2>&1 | tail -5
    [ -x /usr/local/bin/seastar-echo ] && LOG "Seastar echo compiled OK" || LOG "FAILED"
fi

LOG "=== Seastar setup complete ==="
/usr/local/bin/seastar-echo --help 2>&1 | head -3 || true
