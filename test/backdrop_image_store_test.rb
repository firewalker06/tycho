# frozen_string_literal: true

require_relative "support/push_safety"
require_relative "../lib/hq/domain/backdrop_image_store"
require_relative "../lib/hq/remote_server"
require_relative "../lib/hq/cli_command"
require "tmpdir"
require "stringio"

module BackdropImageStoreTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def rejects
    yield
    raise "Expected image rejection"
  rescue HQ::BackdropImageStore::Error
    nil
  end

  def run!
    Dir.mktmpdir("tycho-image-store-") do |dir|
      store = HQ::BackdropImageStore.new(root: File.join(dir, "images"))
      png = ChunkyPNG::Image.new(16, 12, ChunkyPNG::Color.rgb(255, 0, 0)).to_blob
      body = { "name" => "Landscape", "data" => Base64.strict_encode64(png) }
      first = store.upload("landscape", body)
      assert(first["width"] == 16 && first["height"] == 12 && !first.key?("data"), "List must expose bounded metadata only")
      assert(store.list == [first], "Uploaded image must persist")
      assert(HQ::BackdropImageStore.new(root: File.join(dir, "images")).read("landscape")[1].start_with?("\x89PNG".b), "Cold store reads PNG")
      rejects { store.upload("../escape", body) }
      rejects { store.upload("landscape", body.merge("url" => "https://example.test/private.png")) }
      rejects { store.upload("landscape", body.merge("data" => Base64.strict_encode64("<svg/>"))) }
      rejects { store.upload("landscape", body.merge("data" => Base64.strict_encode64(png[0...-5]))) }
      damaged = png.dup
      damaged.setbyte(40, damaged.getbyte(40) ^ 1)
      rejects { store.upload("landscape", body.merge("data" => Base64.strict_encode64(damaged))) }
      too_wide = ChunkyPNG::Image.new(4097, 1).to_blob
      rejects { store.upload("landscape", body.merge("data" => Base64.strict_encode64(too_wide))) }
      bomb = ChunkyPNG::Datastream.from_blob(png)
      bomb.data_chunks = [ChunkyPNG::Chunk::ImageData.new(Zlib.deflate("\0" * (HQ::BackdropImageStore::MAX_INFLATED + 1)))]
      rejects { store.upload("landscape", body.merge("data" => Base64.strict_encode64(bomb.to_blob))) }
      assert(store.list == [first], "Failed replacement preserves the prior image")
      blue = ChunkyPNG::Image.new(16, 12, ChunkyPNG::Color.rgb(0, 0, 255)).to_blob
      second = store.upload("landscape", body.merge("data" => Base64.strict_encode64(blue)))
      assert(second["version"] != first["version"] && store.list.length == 1, "Replacement must change the cache version without leaking old records")
      19.times { |i| store.upload("image-#{i}", body) }
      rejects { store.upload("overflow", body) }
      store.upload("landscape", body)
      stale = File.join(dir, "images", ".#{"a" * 32}.tmp")
      File.binwrite(stale, "interrupted upload")
      store.remove("landscape")
      assert(!File.exist?(stale), "Interrupted uploads are cleaned under the writer lock")
      store.remove("landscape")
      assert(store.list.length == 19 && Dir.glob(File.join(dir, "images", "*.tmp")).empty?, "Removal is idempotent and atomic files leave no receipts")

      # Exercise CLI JSON output and both local and remote dispatch without provider calls.
      file = File.join(dir, "sample.png")
      File.binwrite(file, png)
      output = StringIO.new
      result = HQ::CLICommand.backdrop_images("upload", "cli-fixture", file, { name: "CLI sample" }, out: output, err: StringIO.new)
      assert(result.zero? && JSON.parse(output.string).fetch("image").fetch("id") == "cli-fixture", "CLI upload returns usable metadata")
      service = Object.new
      server = HQ::RemoteServer.new(output: StringIO.new)
      response = server.send(:route, service, "GET", "/appearance/images/cli-fixture/blob", {})
      assert(response[:content_type] == "image/png" && response[:headers]["Cache-Control"] == "private, no-cache", "Read is a private raster with revalidation")
      assert(response[:body].b.start_with?("\x89PNG".b), "API must return original raster bytes")
      server.send(:route, service, "DELETE", "/appearance/images/cli-fixture", {})
      begin
        server.send(:route, service, "GET", "/appearance/images/cli-fixture/blob", {})
        raise "Expected missing image"
      rescue HQ::RemoteServer::Error => e
        assert(e.status == 404, "Removed image must not be served from the server")
      end
      secured = HQ::RemoteServer.new(token: "synthetic-image-token", output: StringIO.new)
      assert(!secured.send(:authorized?, HQ::RemoteServer::Request.new(headers: {})), "Library requires host authentication")
    end
    puts "backdrop_image_store_test: ok"
  end
end

BackdropImageStoreTest.run!
