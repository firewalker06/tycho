# frozen_string_literal: true

require_relative "../lib/hq/terminal_qr"

module TerminalQRTest
  module_function

  def run!
    assert_terminal_qr_renders_half_blocks
    puts "terminal_qr_test: ok"
  end

  def assert_terminal_qr_renders_half_blocks
    output = HQ::TerminalQR.render("http://hq-device.tailnet-name.ts.net:7373/")

    assert(output.include?("▀"), "expected terminal QR to include half-block characters")
    assert(output.include?("\e["), "expected terminal QR to include ANSI colors")
    assert(output.lines.length <= 17, "expected half-block QR to be compact")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

TerminalQRTest.run! if $PROGRAM_NAME == __FILE__
