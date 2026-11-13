# frozen_string_literal: true

require "json"
require_relative "../lib/hq/remote_ui"

# This parity gate keeps browser bootstrap public without making a new API route public.
manifest = JSON.parse(File.read(File.expand_path("../ext/iroh_gateway/public_assets.json", __dir__)))
base = %w[/ /ui /ui/ /ui.css /ui-helpers.js /ui.js /service-worker.js /manifest.webmanifest
          /remote-logo.png /remote-logo-horizontal.png /remote-logo-light.png
          /remote-logo-horizontal-light.png /apple-touch-icon.png /pwa-icon-192.png
          /pwa-icon-512.png /pwa-icon-maskable-512.png /favicon.svg]
expected = base + HQ::RemoteUI::FONT_ASSETS.keys + HQ::RemoteUI::HARNESS_LOGO_ASSETS.keys
abort "Iroh public assets differ from the UI bootstrap contract" unless manifest.sort == expected.sort
abort "Iroh public assets contain duplicates" unless manifest == manifest.uniq
spec = Gem::Specification.load(File.expand_path("../hq.gemspec", __dir__))
%w[Cargo.toml Cargo.lock public_assets.json src/main.rs].each do |file|
  abort "Gem omits optional Iroh source #{file}" unless spec.files.include?("ext/iroh_gateway/#{file}")
end
puts "iroh_gateway_test: ok"
