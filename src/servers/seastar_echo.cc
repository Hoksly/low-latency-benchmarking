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
