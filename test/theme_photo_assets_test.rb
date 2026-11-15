# frozen_string_literal: true

require "json"
require "digest"
require_relative "../lib/hq/remote_ui"

root = HQ::RemoteUI::THEME_PHOTO_ROOT
manifest = JSON.parse(File.read(File.join(root, "provenance.json")))
raise "Expected four photo assets" unless manifest.length == 4
manifest.each do |item|
  bytes = File.binread(File.join(root, item.fetch("file")))
  raise "Invalid WebP" unless bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP"
  raise "Hash mismatch" unless Digest::SHA256.hexdigest(bytes) == item.fetch("sha256")
  raise "Asset too large" unless bytes.bytesize < 500_000
  route = "/theme-photos/#{item.fetch('file')}"
  raise "Missing route" unless HQ::RemoteUI.theme_photo_route?(route)
  raise "Missing version dependency" unless HQ::RemoteUI::ASSET_VERSION_PATHS.include?(File.join(root, item.fetch("file")))
end
legacy_root = File.join(root, "legacy")
JSON.parse(File.read(File.join(legacy_root, "provenance.json"))).each do |item|
  bytes = File.binread(File.join(legacy_root, item.fetch("file")))
  raise "Earlier image was changed" unless Digest::SHA256.hexdigest(bytes) == item.fetch("sha256")
  raise "Earlier credit lost" if item.fetch("creator").empty? || item.fetch("license_url").empty?
end
raise "Unsafe route" if HQ::RemoteUI.theme_photo_route?("/theme-photos/../appearance.js")
raise "Unversioned photo URL" if HQ::RemoteUI.appearance_js.include?("__TYCHO_PHOTO_VERSION__")
%w[CREDITS.txt CC-BY-3.0.txt CC-BY-SA-4.0.txt].each do |file|
  raise "Missing license" unless File.size(File.join(root, file)) > 1000
end
puts "theme_photo_assets_test: ok"
