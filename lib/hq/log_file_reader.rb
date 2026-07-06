# frozen_string_literal: true

module HQ
  module LogFileReader
    module_function

    def read_lines(path, chomp: true)
      return [] unless File.file?(path)

      normalize_text(File.binread(path)).lines(chomp:)
    end

    def tail_lines(path, count, chomp: true)
      return [] unless File.file?(path)

      read_lines(path, chomp:).last(count)
    end

    def read_tail_window_lines(path, max_bytes:, chomp: true)
      return [] unless File.file?(path)

      data = File.open(path, "rb") do |file|
        window = [file.size, max_bytes].min
        file.seek(-window, IO::SEEK_END) if window.positive?
        file.read.to_s
      end
      normalize_text(data).lines(chomp:)
    end

    def foreach_line(path, chomp: false)
      read_lines(path, chomp:).each { |line| yield line }
    end

    def normalize_text(data)
      data.to_s
          .force_encoding(Encoding::UTF_8)
          .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    end
  end
end
