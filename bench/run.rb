# frozen_string_literal: true

# Runs inside one engine's process: `ruby bench/run.rb DOCUMENT ITERATIONS [pdf_ua]`, prints one JSON line.

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

DATA_DIRECTORY = File.expand_path("../corpus/cache/prawn/data", __dir__)

document_path, iterations, standard = ARGV
body = File.read(document_path)
# Tagged for PDF/UA: the structure tree and its marked content, the language, the title and the XMP metadata.
options = (standard == "pdf_ua") ? {pdf: :ua, lang: "en", info: {Title: File.basename(document_path, ".rb").capitalize}} : {}
render =
  if File.basename(File.dirname(document_path)) == "native"
    # A document of Gamba's own API, which compresses unasked, is written against `document`.
    -> { Gamba.document(**options) { |document| eval(body, binding, document_path) }.to_s } # rubocop:disable Security/Eval
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
