# frozen_string_literal: true

require "digest"
require "erb"
require "json"

module HQ
  class RemoteUI
    ROOT = File.expand_path("remote_ui", __dir__)
    TEMPLATE_PATH = File.join(ROOT, "templates", "index.html.erb")
    CSS_PATH = File.join(ROOT, "assets", "app.css")
    HELPERS_JS_PATH = File.join(ROOT, "assets", "app_helpers.js")
    JS_PATH = File.join(ROOT, "assets", "app.js")
    LOGO_PATH = File.join(ROOT, "assets", "tycho-logo.png")
    HORIZONTAL_LOGO_PATH = File.join(ROOT, "assets", "tycho-logo-horizontal.png")
    APPLE_TOUCH_ICON_PATH = File.join(ROOT, "assets", "apple-touch-icon.png")
    PWA_ICON_192_PATH = File.join(ROOT, "assets", "pwa-icon-192.png")
    PWA_ICON_512_PATH = File.join(ROOT, "assets", "pwa-icon-512.png")
    PWA_ICON_MASKABLE_512_PATH = File.join(ROOT, "assets", "pwa-icon-maskable-512.png")
    SERVICE_WORKER_PATH = File.join(ROOT, "assets", "service-worker.js")
    PNG_ASSETS = {
      "remote-logo" => LOGO_PATH,
      "remote-logo-horizontal" => HORIZONTAL_LOGO_PATH,
      "apple-touch-icon" => APPLE_TOUCH_ICON_PATH,
      "pwa-icon-192" => PWA_ICON_192_PATH,
      "pwa-icon-512" => PWA_ICON_512_PATH,
      "pwa-icon-maskable-512" => PWA_ICON_MASKABLE_512_PATH
    }.freeze
    ASSET_VERSION_PATHS = [
      TEMPLATE_PATH,
      CSS_PATH,
      HELPERS_JS_PATH,
      JS_PATH,
      SERVICE_WORKER_PATH,
      *PNG_ASSETS.values
    ].freeze
    FAVICON_SVG = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
        <path d="M7 27a25 25 0 0 1 20-20" fill="none" stroke="#ff8a00" stroke-width="5" stroke-linecap="butt"/>
        <path d="M37 7a25 25 0 0 1 20 20" fill="none" stroke="#f3f1ea" stroke-width="5" stroke-linecap="butt"/>
        <path d="M57 37a25 25 0 0 1-20 20" fill="none" stroke="#f3f1ea" stroke-width="5" stroke-linecap="butt"/>
        <path d="M27 57A25 25 0 0 1 7 37" fill="none" stroke="#9c9c9c" stroke-width="5" stroke-linecap="butt"/>
        <rect x="30" y="24" width="4" height="4" fill="#f3f1ea"/>
        <rect x="30" y="30" width="4" height="4" fill="#f3f1ea"/>
        <rect x="30" y="38" width="4" height="4" fill="#f3f1ea"/>
      </svg>
    SVG

    def self.index
      ERB.new(File.read(TEMPLATE_PATH)).result(binding)
    end

    def self.css
      File.read(CSS_PATH)
    end

    def self.js
      File.read(JS_PATH)
    end

    def self.helpers_js
      File.read(HELPERS_JS_PATH)
    end

    def self.service_worker_js
      File.read(SERVICE_WORKER_PATH)
    end

    def self.manifest_json
      version = asset_version
      JSON.pretty_generate(
        {
          name: "Tycho - Factorio for Agents",
          short_name: "Tycho",
          description: "Remote control for managed HQ agents and projects.",
          id: "/",
          start_url: "/",
          scope: "/",
          display: "standalone",
          background_color: "#282a36",
          theme_color: "#282a36",
          icons: [
            {
              src: "/pwa-icon-192.png?v=#{version}",
              sizes: "192x192",
              type: "image/png"
            },
            {
              src: "/pwa-icon-512.png?v=#{version}",
              sizes: "512x512",
              type: "image/png"
            },
            {
              src: "/pwa-icon-maskable-512.png?v=#{version}",
              sizes: "512x512",
              type: "image/png",
              purpose: "any maskable"
            }
          ]
        }
      )
    end

    def self.png_asset(name)
      File.binread(PNG_ASSETS.fetch(name))
    end

    def self.asset_version
      digest = Digest::SHA256.new
      ASSET_VERSION_PATHS.each { |path| digest.update(File.binread(path)) }
      digest.hexdigest[0, 12]
    end

    def self.favicon_svg
      FAVICON_SVG
    end
  end
end
