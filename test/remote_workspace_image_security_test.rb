# frozen_string_literal: true

require_relative "support/push_safety"
require "socket"
require "timeout"
require "yaml"
require "uri"
require_relative "../lib/hq/remote_server"

Dir.mktmpdir("tycho-image-security") do |dir|
  workspace = File.join(dir, "workspace # ? %23")
  docs = File.join(workspace, "docs #1 ? 100%")
  FileUtils.mkdir_p(docs)
  FileUtils.mkdir_p(File.join(workspace, ".ssh"))
  public_bytes = "<svg><title>public blue image</title></svg>"
  private_bytes = "<svg><title>PRIVATE_IMAGE_SENTINEL</title></svg>"
  image = File.join(docs, "image#?%.svg")
  File.write(image, public_bytes)
  File.write(File.join(workspace, ".ssh", "private.svg"), private_bytes)
  File.write(File.join(dir, "outside.svg"), private_bytes)
  File.symlink(image, File.join(workspace, "safe.svg"))
  File.symlink(docs, File.join(workspace, "safe-docs"))
  File.symlink(File.join(workspace, ".ssh", "private.svg"), File.join(workspace, "public.svg"))
  File.symlink(File.join(workspace, ".ssh"), File.join(workspace, "private-alias"))
  File.symlink(File.join(dir, "outside.svg"), File.join(workspace, "outside.svg"))
  config = File.join(dir, "hq.yml")
  prompts = File.join(dir, "prompts.yml")
  linked_root = File.join(dir, "linked-root")
  File.symlink(workspace, linked_root)
  File.write(config, YAML.dump("projects" => [
    { "key" => "fixture", "name" => "Fixture", "path" => workspace },
    { "key" => "linked", "name" => "Linked root", "path" => linked_root }
  ]))
  File.write(prompts, YAML.dump("default" => "Synthetic fixture"))
  registry = HQ::Registry.new(path: config, system_prompts_path: prompts)
  server = HQ::RemoteServer.new(registry: registry, token: "synthetic-image-token", output: StringIO.new)
  paths = [
    ["docs #1 ? 100%/image#?%.svg", 200], ["safe.svg", 200], ["safe-docs/image#?%.svg", 200],
    [".ssh/private.svg", 404], ["public.svg", 404], ["private-alias/private.svg", 404],
    ["outside.svg", 400], ["../outside.svg", 400], ["%2e%2e/outside.svg", 400]
  ]
  %w[fixture linked].product(paths).each do |project_key, (path, expected)|
    accepted, client = Socket.pair(:UNIX, :STREAM, 0)
    worker = Thread.new { server.send(:handle_client, accepted) }
    query = URI.encode_www_form("path" => path)
    client.write("GET /projects/#{project_key}/workspace/image?#{query} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer synthetic-image-token\r\n\r\n")
    response = Timeout.timeout(5) { client.read }
    raise "#{path.inspect}: expected #{expected}, got #{response.lines.first}" unless response.start_with?("HTTP/1.1 #{expected}")
    raise "private bytes leaked through #{path}" if response.include?("PRIVATE_IMAGE_SENTINEL")
    raise "wrong image bytes for reserved metadata #{path}" if expected == 200 && !response.end_with?(public_bytes)
  ensure
    client&.close unless client&.closed?
    accepted&.close unless accepted&.closed?
    worker&.join(5)
  end
end
puts "remote_workspace_image_security_test: reserved paths, safe/private/external symlinks and encoded traversal passed"
