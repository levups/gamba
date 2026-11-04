# frozen_string_literal: true

# Renders each document of bench/documents with Prawn and with PrawnX, each in its own YJIT process, and writes
# median time, allocations, peak memory and file weight to docs/benchmarks.json.

require "bundler"
require "json"
require "open3"
require_relative "../test/support/oracle"

ITERATIONS = Integer(ENV.fetch("BENCH_ITERATIONS", "20"))
TIME_COMMAND = RUBY_PLATFORM.include?("darwin") ? ["/usr/bin/time", "-l"] : ["/usr/bin/time", "-v"]

def peak_memory_megabytes(time_report)
  if RUBY_PLATFORM.include?("darwin")
    (Integer(time_report[/(\d+)\s+maximum resident set size/, 1]) / 1_048_576.0).round(1)
  else
    (Integer(time_report[/Maximum resident set size \(kbytes\): (\d+)/, 1]) / 1024.0).round(1)
  end
end

def measure(engine, document)
  settings = Oracle::ENGINES.fetch(engine)
  command = [*TIME_COMMAND, "bundle", "exec", "ruby", "--yjit", *settings[:load_path], File.join(__dir__, "run.rb"), document, ITERATIONS.to_s]
  output, report, status = Bundler.with_unbundled_env { Open3.capture3({"BUNDLE_GEMFILE" => settings[:gemfile]}, *command) }
  return {unavailable: report.lines.find { _1.match?(/cannot load|Error/) }&.strip} unless status.success?

  JSON.parse(output.lines.last, symbolize_names: true).merge(peak_memory_megabytes: peak_memory_megabytes(report))
end

results = Dir[File.join(__dir__, "documents/*.rb")].sort.to_h do |document|
  [File.basename(document, ".rb"), Oracle::ENGINES.keys.to_h { |engine| [engine, measure(engine, document)] }]
end

results.each do |document, measures_by_engine|
  measures_by_engine.each do |engine, measures|
    summary = measures[:unavailable] ? "unavailable (#{measures[:unavailable]})" : measures.map { |name, value| "#{name} #{value}" }.join(", ")
    puts format("%-10s %-7s %s", document, engine, summary)
  end
end
File.write(File.expand_path("../docs/benchmarks.json", __dir__), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, iterations: ITERATIONS, results:) + "\n")
