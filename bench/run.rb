# frozen_string_literal: true

# Runs inside one engine's process, as bench/compare.rb starts it (`bundle exec ruby -Ilib bench/run.rb DOCUMENT
# ITERATIONS [pdf_ua]` for Gamba), and prints one JSON line.

require "json"
begin
  require "prawn"
rescue LoadError => exception
  abort "This engine cannot load: #{exception.message}"
end
begin
  require "prawn/table"
rescue LoadError
  # Documents with tables then fail on their own, reported as unavailable for this engine.
end

require_relative "native_bench"

DATA_DIRECTORY = NativeBench::DATA_DIRECTORY

document_path, iterations, standard = ARGV
body = File.read(document_path)
native = File.basename(File.dirname(document_path)) == "native"
abort "Error: unknown standard #{standard.inspect}, the only one is pdf_ua" if standard && !NativeBench::STANDARDS.include?(standard)
abort "Error: pdf_ua tags Gamba's own API, a document of bench/native, not #{document_path}" if standard && !native
render =
  if native
    -> { NativeBench.render(body, document_path, standard) }
  else
    # Prawn compresses only when asked: compared at its lightest.
    -> { Prawn::Document.new(compress: true).tap { _1.instance_eval(body, document_path) }.render }
  end

pdf = render.call
GC.start
allocations_before = GC.stat(:total_allocated_objects)
render.call
allocations = GC.stat(:total_allocated_objects) - allocations_before

durations = Array.new(Integer(iterations)) do
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  render.call
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
end

puts JSON.generate(median_milliseconds: (durations.sort[durations.size / 2] * 1000).round(1), allocations:, bytes: pdf.bytesize)
