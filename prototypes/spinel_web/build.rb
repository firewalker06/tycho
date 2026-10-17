#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"

root = __dir__
output = File.expand_path(ARGV.fetch(0))
compiler = ARGV[1]
FileUtils.mkdir_p(output)
assets = +"# frozen_string_literal: true\nmodule PrototypeAssets\n"
{ "HTML" => "index.html", "JS" => "app.js", "CSS" => "app.css" }.each do |name, file|
  assets << "  #{name} = #{File.read(File.join(root, file)).dump}\n"
end
assets << "end\n"
entry = File.join(output, "prototype.rb")
File.write(entry, assets + File.read(File.join(root, "app.rb")))
if compiler
  abort "Spinel compile failed" unless system(compiler, entry, "-o", File.join(output, "tycho-prototype"))
end
puts entry
