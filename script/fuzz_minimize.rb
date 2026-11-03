# frozen_string_literal: true

# Shrinks a document from the fuzzer to the fewest top-level statements that still render differently from Prawn:
# `ruby -Itest script/fuzz_minimize.rb tmp/fuzz/documents/fuzz_0031.rb`.
require "fileutils"
require_relative "../test/support/oracle"

path = ARGV.fetch(0)
setup, *statements = File.read(path).split(/\n(?=\S)/)
directory = File.join(Oracle::ROOT, "tmp/minimize")

differs = lambda do |kept|
  FileUtils.rm_rf(directory)
  FileUtils.mkdir_p(directory)
  file = File.join(directory, "minimal.rb")
  File.write(file, [setup, *kept].join("\n"))
  reference = Oracle.render("prawn", [file], File.join(directory, "prawn"))
  candidate = Oracle.render("prawnx", [file], File.join(directory, "prawnx"))
  !Oracle.differences(reference, candidate, "minimal").empty?
end

abort "#{path} renders like Prawn" unless differs.call(statements)

index = 0
while index < statements.size
  shorter = statements.dup.tap { _1.delete_at(index) }
  if differs.call(shorter)
    statements = shorter
  else
    index += 1
  end
end
puts [setup, *statements].join("\n")
