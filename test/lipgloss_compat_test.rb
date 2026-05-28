# frozen_string_literal: true

require "open3"

ROOT = File.expand_path("..", __dir__)

def run_ruby_lipgloss(source, env = {})
  command = ["bundle", "exec", "ruby", "-Ilib", "-e", source]
  output, status = Open3.capture2e(env, *command, chdir: ROOT)
  raise "command failed:\n#{output}" unless status.success?

  output
end

run_ruby_lipgloss(<<~RUBY, "TYCHO_LIPGLOSS_BACKEND" => "ruby")
  require "lipgloss"

  raise "expected ruby backend" unless Lipgloss::BACKEND == :ruby

  rendered = Lipgloss::Style.new.border(:rounded).padding(0, 1).width(10).render("x")
  plain = rendered.gsub(/\\e\\[[0-9;]*[A-Za-z]/, "")
  expected = "╭──────────╮\\n│ x        │\\n╰──────────╯"
  raise "unexpected styled box: \#{plain.inspect}" unless plain == expected

  joined = Lipgloss.join_horizontal(:bottom, "a\\nbb", "ccc")
  raise "unexpected horizontal join: \#{joined.inspect}" unless joined == "a    \\nbbccc"

  list = Lipgloss::List.new.enumerator(:bullet).items(["one", "two\\nmore"]).render
  raise "unexpected list: \#{list.inspect}" unless list == "• one\\n• two\\n  more"

  table = Lipgloss::Table.new.headers(%w[A B]).rows([["aa", "bbb"]]).render
  raise "expected table borders" unless table.include?("╭──┬───╮") && table.include?("│aa│bbb│")
RUBY

run_ruby_lipgloss(<<~RUBY, "TYCHO_LIPGLOSS_BACKEND" => "ruby")
  require "bubbletea"
  require "lipgloss"
  require "bubbles"

  progress = Bubbles::Progress.new(width: 10, gradient: %w[#000000 #FFFFFF]).view_as(0.5)
  plain = Bubbles::ANSI.strip(progress)
  raise "expected progress bar to render through compat Lipgloss" unless plain == "███░░  50%"
RUBY

doctor_output = run_ruby_lipgloss(<<~RUBY, "TYCHO_LIPGLOSS_BACKEND" => "ruby")
  require "open3"

  output, status = Open3.capture2e("bundle", "exec", "bin/tycho", "doctor", chdir: #{ROOT.inspect})
  raise output unless status.success?
  raise "expected doctor success" unless output.include?("Tycho doctor: ok")
  raise "expected ruby backend" unless output.include?("Lipgloss backend: ruby")
  raise "expected native Lipgloss to stay unloaded" unless output.include?("Native Lipgloss loaded: no")
  puts output
RUBY
raise "expected doctor output" unless doctor_output.include?("Tycho doctor: ok")

puts "lipgloss_compat_test: ok"
