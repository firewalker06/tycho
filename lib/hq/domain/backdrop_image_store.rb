# frozen_string_literal: true

require "base64"
require "chunky_png"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "zlib"
require_relative "constants"
require_relative "file_store"

module HQ
  # A server library. Each atomic record owns its metadata and raster together.
  class BackdropImageStore
    MAX_BYTES = 5 * 1024 * 1024
    MAX_IMAGES = 20
    MAX_INFLATED = 64 * 1024 * 1024
    class Error < ArgumentError; end

    def initialize(root: File.join(USER_LOGS_DIR, "backdrop_images"))
      @root = root
    end

    def list
      locked { entries.map { |record| metadata(record) } }
    end

    def upload(id, body)
      validate_id(id)
      raise Error, "Use only name and data fields" unless body.is_a?(Hash) && (body.keys - %w[name data]).empty?
      name = body["name"]
      raise Error, "Use a name with 1 to 120 characters" unless name.is_a?(String) && !name.strip.empty? && name.length <= 120 && !name.match?(/[[:cntrl:]]/)
      encoded = body["data"]
      raise Error, "PNG must be at most 5 MiB" unless encoded.is_a?(String) && encoded.bytesize <= ((MAX_BYTES + 2) / 3) * 4
      begin
        bytes = Base64.strict_decode64(encoded)
      rescue ArgumentError
        raise Error, "Invalid base64 image data"
      end
      raster = normalize(bytes)
      record = { "id" => id, "name" => name.strip, "version" => Digest::SHA256.hexdigest(raster),
                 "width" => @width, "height" => @height, "bytes" => raster.bytesize, "mime" => "image/png" }
      locked do
        raise Error, "Remove an image first (20 images maximum)" if !File.exist?(path(id)) && entries.length >= MAX_IMAGES
        temporary = File.join(@root, ".#{SecureRandom.hex(16)}.tmp")
        begin
          File.open(temporary, "wb", 0o600) do |file|
            file.write(JSON.generate(record) + "\n")
            file.write(raster)
            file.flush
            file.fsync
          end
          File.rename(temporary, path(id))
          FileStore.fsync_directory(@root)
        ensure
          File.unlink(temporary) if File.exist?(temporary)
        end
        metadata(record)
      end
    end

    def read(id)
      validate_id(id)
      locked do
        raise Error, "Image not found" unless File.file?(path(id))
        File.open(path(id), "rb") do |file|
          record = read_metadata(file)
          raster = file.read(MAX_BYTES + 1)
          raise Error, "Saved image is damaged" unless raster.bytesize == record["bytes"] && Digest::SHA256.hexdigest(raster) == record["version"]
          [record, raster]
        end
      end
    end

    def remove(id)
      validate_id(id)
      locked { File.unlink(path(id)) if File.exist?(path(id)) }
      { removed: id }
    end

    private

    def validate_id(id)
      raise Error, "Use an image id: a letter, then letters, digits or hyphens (40 maximum)" unless id.is_a?(String) && id.match?(/\A[a-z][a-z0-9-]{0,39}\z/)
    end

    def path(id)
      File.join(@root, "#{id}.image")
    end

    def metadata(record)
      record.dup
    end

    def entries
      Dir.glob(File.join(@root, "*.image")).sort.map do |path|
        File.open(path, "rb") { |file| read_metadata(file) }
      end
    end

    def read_metadata(file)
      line = file.gets(2048)
      raise Error, "Saved image metadata is damaged" unless line&.end_with?("\n")
      JSON.parse(line)
    rescue JSON::ParserError
      raise Error, "Saved image metadata is damaged"
    end

    def locked
      FileUtils.mkdir_p(@root, mode: 0o700)
      File.open(File.join(@root, ".lock"), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        # An exclusive writer cannot have a live temporary file from another call.
        Dir.glob(File.join(@root, ".*.tmp")).each do |temporary|
          File.unlink(temporary) if File.basename(temporary).match?(/\A\.[a-f0-9]{32}\.tmp\z/)
        end
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def normalize(bytes)
      raise Error, "Upload a PNG raster, at most 5 MiB" if bytes.empty? || bytes.bytesize > MAX_BYTES || !bytes.start_with?("\x89PNG\r\n\x1a\n".b)
      # Check CRCs and bound decompression before the pixel decoder allocates.
      offset = 8
      inflated = 0
      inflater = Zlib::Inflate.new
      ended = false
      safe_png = bytes.byteslice(0, 8).dup
      while offset + 12 <= bytes.bytesize
        size = bytes.byteslice(offset, 4).unpack1("N")
        type = bytes.byteslice(offset + 4, 4)
        data = bytes.byteslice(offset + 8, size)
        raise Error, "Invalid PNG chunks" unless data && offset + size + 12 <= bytes.bytesize
        crc = bytes.byteslice(offset + size + 8, 4).unpack1("N")
        raise Error, "Invalid PNG checksum" unless Zlib.crc32(type + data) == crc
        if offset == 8
          raise Error, "Invalid PNG header" unless type == "IHDR" && size == 13
          @width, @height = data.unpack("NN")
          raise Error, "Image limit: 4096 pixels per side, 12 megapixels" unless @width.positive? && @height.positive? && @width <= 4096 && @height <= 4096 && @width * @height <= 12_000_000
        end
        if type == "IDAT"
          inflater.inflate(data) do |chunk|
            inflated += chunk.bytesize
            raise Error, "PNG decoded data is too large" if inflated > MAX_INFLATED
          end
        end
        raise Error, "Duplicate PNG header" if type == "IHDR" && offset != 8
        safe_png << bytes.byteslice(offset, size + 12) if %w[IHDR PLTE tRNS IDAT IEND].include?(type)
        offset += size + 12
        if type == "IEND"
          ended = true
          break
        end
      end
      raise Error, "Incomplete PNG" unless ended && offset == bytes.bytesize && inflater.finished?
      image = ChunkyPNG::Image.from_blob(safe_png)
      raster = image.to_blob
      raise Error, "Normalized PNG exceeds 5 MiB" if raster.bytesize > MAX_BYTES
      raster
    rescue ChunkyPNG::Exception, Zlib::Error, NoMethodError, RangeError
      raise Error, "PNG cannot be decoded"
    ensure
      inflater&.close
    end
  end
end
