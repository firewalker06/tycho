# frozen_string_literal: true

require "open3"
require "tempfile"

Tempfile.create(["tycho-raster", ".js"]) do |script|
  script.write(<<~'JS')
    const assert = require("node:assert/strict");
    const { dimensions, checkDimensions, inspect } = require(process.cwd() + "/lib/hq/remote_ui/assets/backdrop_images.js");
    (async () => {
      const png = Buffer.alloc(24); Buffer.from([137,80,78,71,13,10,26,10]).copy(png); png.write("IHDR", 12); png.writeUInt32BE(1200, 16); png.writeUInt32BE(800, 20);
      assert.deepEqual(dimensions(png, "image/png"), [1200, 800]);
      const jpeg = Buffer.from([255,216,255,192,0,7,8,0,80,0,120]);
      assert.deepEqual(dimensions(jpeg, "image/jpeg"), [120, 80]);
      const webp = Buffer.alloc(30); webp.write("RIFF"); webp.write("WEBP", 8); webp.write("VP8X", 12); webp[24] = 119; webp[27] = 79;
      assert.deepEqual(dimensions(webp, "image/webp"), [120, 80]);
      webp.write("VP8L", 12); webp[20] = 47; webp[21] = 119; webp[22] = 192; webp[23] = 19; webp[24] = 0;
      assert.deepEqual(dimensions(webp, "image/webp"), [120, 80]);
      assert.throws(() => dimensions(Buffer.from("<svg/>"), "image/png"), /not a supported/);
      assert.throws(() => dimensions(png, "image/jpeg"), /not a supported/);
      for (const size of [[0, 1], [5000, 10], [4096, 4096]]) assert.throws(() => checkDimensions(...size), /dimensions/);
      checkDimensions(4096, 2000);
      await inspect(new Blob([png], { type: "image/png" }));
      await assert.rejects(inspect(new Blob([png], { type: "image/svg+xml" })), /raster image/);
      await assert.rejects(inspect(new Blob([Buffer.alloc(5 * 1024 * 1024 + 1)], { type: "image/png" })), /5 MiB/);
      console.log("raster validation: ok");
    })().catch(error => { console.error(error); process.exit(1); });
  JS
  script.flush
  out, err, status = Open3.capture3("node", script.path, chdir: File.expand_path("..", __dir__))
  raise "Raster validation failed:\n#{out}#{err}" unless status.success?
end
puts "remote_ui_backdrop_images_test: ok"
