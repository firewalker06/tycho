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
  percent_docs = File.join(workspace, "docs%23")
  hash_docs = File.join(workspace, "docs#")
  FileUtils.mkdir_p(percent_docs)
  FileUtils.mkdir_p(hash_docs)
  hash_bytes = "<svg><title>distinct actual hash image</title></svg>"
  File.write(File.join(percent_docs, "image%23.svg"), public_bytes)
  File.write(File.join(percent_docs, "image#.svg"), hash_bytes)
  File.write(File.join(hash_docs, "image%23.svg"), hash_bytes)
  File.write(File.join(workspace, "image%23.svg"), public_bytes)
  File.write(File.join(workspace, "image#.svg"), hash_bytes)
  File.write(File.join(workspace, "%2e%2e%2foutside.svg"), public_bytes)
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
    ["docs%23/image%23.svg", 200], ["image%23.svg", 200], ["%2e%2e%2foutside.svg", 200],
    ["docs%23/image#.svg", 200, hash_bytes], ["docs#/image%23.svg", 200, hash_bytes], ["image#.svg", 200, hash_bytes],
    [".ssh/private.svg", 404], ["public.svg", 404], ["private-alias/private.svg", 404],
    ["outside.svg", 400], ["../outside.svg", 400], ["%2e%2e/outside.svg", 404]
  ]
  # These are raw wire queries. The handler must decode transport once and then
  # retain the resulting filename, even when it resembles another URL escape.
  requests = paths.map do |path, expected, bytes|
    [URI.encode_www_form("path" => path), expected, bytes, "synthetic-image-token"]
  end
  requests.concat([
    ["path=docs%2523%2Fimage%2523.svg", 200, public_bytes, "synthetic-image-token"],
    ["path=docs%2523%2Fimage%23.svg", 200, hash_bytes, "synthetic-image-token"],
    ["path=%2e%2e%2foutside.svg", 400, nil, "synthetic-image-token"],
    ["path=%2e%2e%5coutside.svg", 400, nil, "synthetic-image-token"],
    ["path=%252e%252e%252foutside.svg", 200, public_bytes, "synthetic-image-token"],
    ["path=%2essh%2fprivate.svg", 404, nil, "synthetic-image-token"],
    ["path=%2Foutside.svg", 400, nil, "synthetic-image-token"],
    ["path=docs%2523%2Fimage%2523.svg", 401, nil, nil],
    ["path=docs%2523%2Fimage%2523.svg", 401, nil, "wrong-token"]
  ])
  %w[fixture linked].product(requests).each do |project_key, (query, expected, expected_bytes, token)|
    accepted, client = Socket.pair(:UNIX, :STREAM, 0)
    worker = Thread.new { server.send(:handle_client, accepted) }
    authorization = token ? "Authorization: Bearer #{token}\r\n" : ""
    client.write("GET /projects/#{project_key}/workspace/image?#{query} HTTP/1.1\r\nHost: localhost\r\n#{authorization}\r\n")
    response = Timeout.timeout(5) { client.read }
    raise "#{query.inspect}: expected #{expected}, got #{response.lines.first}" unless response.start_with?("HTTP/1.1 #{expected}")
    raise "private bytes leaked through #{query}" if response.include?("PRIVATE_IMAGE_SENTINEL")
    raise "wrong image bytes for #{query}" if expected == 200 && !response.end_with?(expected_bytes || public_bytes)
  ensure
    client&.close unless client&.closed?
    accepted&.close unless accepted&.closed?
    worker&.join(5)
  end
end
puts "remote_workspace_image_security_test: decoded-once literal percent/hash paths, auth, safe/private/external symlinks and actual traversal passed"
