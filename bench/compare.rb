# frozen_string_literal: true

# Renders each document of bench/documents with Prawn and with Gamba, in PROCESSES fresh YJIT processes per engine,
# and writes the median of each measure across them (time, allocations, peak memory, file weight) to
# docs/benchmarks.json. Peak memory varies by 20% from one process to the next: one process proves nothing.

require "bundler"
require "json"
require "open3"
require_relative "../test/support/oracle"

ITERATIONS = Integer(ENV.fetch("BENCH_ITERATIONS", "20"))
PROCESSES = Integer(ENV.fetch("BENCH_PROCESSES", "7"))
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

def median(values)
  values.sort[values.size / 2]
end

# The engines take turns, so a slower moment of the machine weighs on both.
def median_measures(document)
  samples_by_engine = Oracle::ENGINES.keys.to_h { |engine| [engine, []] }
  PROCESSES.times { samples_by_engine.each { |engine, samples| samples << measure(engine, document) } }
  samples_by_engine.transform_values do |samples|
    unavailable = samples.find { |sample| sample[:unavailable] }
    next unavailable if unavailable

    samples.first.keys.to_h { |name| [name, median(samples.map { |sample| sample[name] })] }
  end
end

results = Dir[File.join(__dir__, "documents/*.rb")].sort.to_h do |document|
  [File.basename(document, ".rb"), median_measures(document)]
end

results.each do |document, measures_by_engine|
  measures_by_engine.each do |engine, measures|
    summary = measures[:unavailable] ? "unavailable (#{measures[:unavailable]})" : measures.map { |name, value| "#{name} #{value}" }.join(", ")
    puts format("%-10s %-7s %s", document, engine, summary)
  end
end
File.write(File.expand_path("../docs/benchmarks.json", __dir__), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, iterations: ITERATIONS, processes: PROCESSES, results:) + "\n")
