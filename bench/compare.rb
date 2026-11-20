# frozen_string_literal: true

# Renders each document of bench/documents with Prawn and with Gamba, and its bench/native version with Gamba's own
# API untagged then tagged for PDF/UA, in PROCESSES fresh YJIT processes per column, and writes the median of each
# measure across them (time, allocations, peak memory, file weight) to docs/benchmarks.json. Peak memory varies by 20%
# from one process to the next: one process proves nothing.

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

def measure(engine, document, standard = nil)
  settings = Oracle::ENGINES.fetch(engine)
  command = [*TIME_COMMAND, "bundle", "exec", "ruby", "--yjit", *settings[:load_path], File.join(__dir__, "run.rb"), document, ITERATIONS.to_s, *standard]
  output, report, status = Bundler.with_unbundled_env { Open3.capture3({"BUNDLE_GEMFILE" => settings[:gemfile]}, *command) }
  return {unavailable: (report.lines.find { _1.match?(/cannot load|Error/) } || "exit #{status.exitstatus}").strip} unless status.success?

  JSON.parse(output.lines.last, symbolize_names: true).merge(peak_memory_megabytes: peak_memory_megabytes(report))
end

def median(values)
  values.sort[values.size / 2]
end

# What each column of the results renders: the document with Prawn's API on each engine, and with Gamba's own API
# where bench/native has it, untagged then tagged for PDF/UA.
def candidates(document)
  native = File.join(__dir__, "native", File.basename(document))
  columns = Oracle::ENGINES.keys.to_h { |engine| [engine, [engine, document]] }
  return columns unless File.exist?(native)

  columns.merge("gamba_native" => ["gamba", native], "gamba_tagged" => ["gamba", native, "pdf_ua"])
end

# The columns take turns, each round starting one further, so a slower moment of the machine, or following
# another column, weighs on each alike.
def median_measures(document)
  columns = candidates(document)
  samples_by_column = columns.keys.to_h { |column| [column, []] }
  PROCESSES.times do |round|
    columns.to_a.rotate(round).each { |column, (engine, path, standard)| samples_by_column[column] << measure(engine, path, standard) }
  end
  samples_by_column.transform_values do |samples|
    unavailable = samples.find { |sample| sample[:unavailable] }
    next unavailable if unavailable

    samples.first.keys.to_h { |name| [name, median(samples.map { |sample| sample[name] })] }
  end
end

results = Dir[File.join(__dir__, "documents/*.rb")].sort.to_h do |document|
  [File.basename(document, ".rb"), median_measures(document)]
end

results.each do |document, measures_by_column|
  measures_by_column.each do |column, measures|
    summary = measures[:unavailable] ? "unavailable (#{measures[:unavailable]})" : measures.map { |name, value| "#{name} #{value}" }.join(", ")
    puts format("%-10s %-12s %s", document, column, summary)
  end
end
# The page draws Gamba's columns for every document: one that failed is a bug to fix, not a gap to publish.
failed = results.flat_map { |document, measures| measures.select { |column, measure| column.start_with?("gamba") && measure[:unavailable] }.keys.map { "#{document} #{_1}" } }
abort "Gamba failed on #{failed.join(", ")}: docs/benchmarks.json left as it was" if failed.any?
File.write(File.expand_path("../docs/benchmarks.json", __dir__), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, iterations: ITERATIONS, processes: PROCESSES, results:) + "\n")
