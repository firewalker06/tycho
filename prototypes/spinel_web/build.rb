#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

root = __dir__
output = File.expand_path(ARGV.fetch(0))
compiler = ARGV[1]
windows = RUBY_PLATFORM.match?(/mingw|mswin/)
abort "Windows requires a Spinel compiler" if windows && !compiler
FileUtils.mkdir_p(output)
assets = +"# frozen_string_literal: true\nmodule PrototypeAssets\n"
{ "HTML" => "index.html", "JS" => "app.js", "CSS" => "app.css" }.each do |name, file|
  assets << "  #{name} = #{File.read(File.join(root, file)).dump}\n"
end
assets << "end\n"
if windows
  object = File.join(output, "windows_native.o")
  archive = File.join(output, "libtycho_windows.a")
  abort "Windows adapter compile failed" unless system("gcc", "-O2", "-Wall", "-Wextra", "-Werror", "-c", File.join(root, "windows_native.c"), "-o", object)
  abort "Windows adapter archive failed" unless system("ar", "rcs", archive, object)
  assets << "module PrototypeWindows\n  ffi_cflags #{("-L" + output).dump}\nend\n"
end
assets << File.read(File.join(root, windows ? "platform_windows.rb" : "platform_posix.rb"))
entry = File.join(output, "prototype.rb")
File.write(entry, assets + File.read(File.join(root, "app.rb")))
if compiler
  abort "Spinel compile failed" unless system(compiler, entry, "-o", File.join(output, windows ? "tycho-prototype.exe" : "tycho-prototype"))
end
puts entry
