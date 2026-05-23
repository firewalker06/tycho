# frozen_string_literal: true

require_relative "../lib/hq/tailscale"

module TailscaleTest
  module_function

  def run!
    assert_parse_running_self_status
    assert_parse_serve_https_url
    assert_parse_serve_https_url_ignores_wrong_target_port
    assert_parse_serve_https_url_ignores_missing_config
    assert_parse_ignores_stopped_backend
    puts "tailscale_test: ok"
  end

  def assert_parse_running_self_status
    info = HQ::Tailscale.parse_self_status(<<~JSON)
      {
        "BackendState": "Running",
        "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::e43b:ec58"],
        "Self": {
          "HostName": "hq-device",
          "DNSName": "hq-device.tailnet-name.ts.net.",
          "Capabilities": ["https"],
          "CapMap": { "https": null }
        },
        "CertDomains": ["hq-device.tailnet-name.ts.net"]
      }
    JSON

    assert(info, "expected running tailscale status to parse")
    assert(info.ip == "100.64.0.10", "expected IPv4 tailscale address")
    assert(info.dns_name == "hq-device.tailnet-name.ts.net", "expected trailing dot stripped from MagicDNS")
    assert(info.https_capable?, "expected HTTPS capability from Tailscale status")
    assert(info.https_dns_name == "hq-device.tailnet-name.ts.net", "expected cert domain to be recorded")
    assert(info.https_url == "https://hq-device.tailnet-name.ts.net/", "expected HTTPS UI URL")
    assert(info.magic_dns_url(port: 7373) == "http://hq-device.tailnet-name.ts.net:7373/",
           "expected MagicDNS UI URL")
  end

  def assert_parse_serve_https_url
    url = HQ::Tailscale.parse_serve_https_url(
      <<~JSON,
      {
        "TCP": {
          "443": {
            "HTTPS": true
          }
        },
        "Web": {
          "hq-device.tailnet-name.ts.net:443": {
            "Handlers": {
              "/": {
                "Proxy": "http://127.0.0.1:7373"
              }
            }
          }
        }
      }
      JSON
      dns_name: "hq-device.tailnet-name.ts.net",
      port: 7373
    )

    assert(url == "https://hq-device.tailnet-name.ts.net/", "expected HTTPS Serve URL")
  end

  def assert_parse_serve_https_url_ignores_wrong_target_port
    url = HQ::Tailscale.parse_serve_https_url(
      <<~JSON,
      {
        "TCP": {
          "443": {
            "HTTPS": true
          }
        },
        "Web": {
          "hq-device.tailnet-name.ts.net:443": {
            "Handlers": {
              "/": {
                "Proxy": "http://127.0.0.1:3000"
              }
            }
          }
        }
      }
      JSON
      dns_name: "hq-device.tailnet-name.ts.net",
      port: 7373
    )

    assert(url.nil?, "expected unrelated Serve proxy to be ignored")
  end

  def assert_parse_serve_https_url_ignores_missing_config
    url = HQ::Tailscale.parse_serve_https_url(
      "{}",
      dns_name: "hq-device.tailnet-name.ts.net",
      port: 7373
    )

    assert(url.nil?, "expected missing Serve config to be ignored")
  end

  def assert_parse_ignores_stopped_backend
    info = HQ::Tailscale.parse_self_status(<<~JSON)
      {
        "BackendState": "Stopped",
        "TailscaleIPs": ["100.64.0.10"],
        "Self": { "DNSName": "hq-device.tailnet-name.ts.net." }
      }
    JSON

    assert(info.nil?, "expected stopped tailscale status to be ignored")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

TailscaleTest.run! if $PROGRAM_NAME == __FILE__
