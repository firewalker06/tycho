# frozen_string_literal: true

require "rqrcode"

module HQ
  module TerminalQR
    QUIET_ZONE_SIZE = 2
    BLACK_ON_BLACK = "\e[30;40m"
    BLACK_ON_WHITE = "\e[30;47m"
    WHITE_ON_BLACK = "\e[37;40m"
    WHITE_ON_WHITE = "\e[37;47m"
    RESET = "\e[0m"

    module_function

    def render(value)
      qr = RQRCode::QRCode.new(value.to_s, level: :l)
      matrix = padded_matrix(qr)
      rows = []

      (0...matrix.length).step(2) do |y|
        row = +""
        matrix.length.times do |x|
          top = matrix[y][x]
          bottom = matrix[y + 1]&.[](x)
          row << half_block_cell(top, bottom)
        end
        rows << "#{row}#{RESET}"
      end

      rows.join("\n")
    end

    def padded_matrix(qr)
      modules = qr.qrcode.modules
      size = modules.length + (QUIET_ZONE_SIZE * 2)
      Array.new(size) do |y|
        Array.new(size) do |x|
          source_y = y - QUIET_ZONE_SIZE
          source_x = x - QUIET_ZONE_SIZE
          source_y.between?(0, modules.length - 1) &&
            source_x.between?(0, modules.length - 1) &&
            modules[source_y][source_x]
        end
      end
    end

    def half_block_cell(top, bottom)
      if top && bottom
        "#{BLACK_ON_BLACK} "
      elsif top
        "#{BLACK_ON_WHITE}▀"
      elsif bottom
        "#{WHITE_ON_BLACK}▀"
      else
        "#{WHITE_ON_WHITE} "
      end
    end
  end
end
