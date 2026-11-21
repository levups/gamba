# frozen_string_literal: true

# Renders each document of bench/documents with Prawn and with Gamba, its bench/mixed version (Prawn code holding one
# block of Gamba's own API) with Gamba, and its bench/native version with Gamba's own API untagged then tagged for
# PDF/UA, in PROCESSES fresh YJIT processes per column, and writes the median of each
# measure across them (time, allocations, peak memory, file weight) to docs/benchmarks.json. Peak memory varies by 20%
# from one process to the next: one process proves nothing.

require "bundler"
require "json"
require "open3"
require "shellwords"
require_relative "../test/support/oracle"
require_relative "native_bench"

ITERATIONS = Integer(ENV.fetch("BENCH_ITERATIONS", "20"))
PROCESSES = Integer(ENV.fetch("BENCH_PROCESSES", "8"))
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
  # The page draws every column of every document and divides by Prawn's: a failed one is a bug to fix, not a gap
  # to publish, and the first failure says so without waiting for the other runs.
  unless status.success?
    abort "#{engine} failed on #{document}#{" with #{standard}" if standard} (#{status}), docs/benchmarks.json left as it was. " \
      "BUNDLE_GEMFILE=#{Shellwords.escape(settings[:gemfile])} #{Shellwords.join(command.drop(TIME_COMMAND.size))}:\n#{report.scrub}"
  end

  JSON.parse(output.lines.last, symbolize_names: true).merge(peak_memory_megabytes: peak_memory_megabytes(report))
end

# Of an even count, the mean of the two middle values, so that no column leans to its slower half, rounded half to
# even so that ties do not all lean up.
def median(values)
  sorted = values.sort
  middle = sorted.size / 2
  return sorted[middle] if sorted.size.odd?

  mean = (sorted[middle - 1] + sorted[middle]) / 2.0
  sorted.all?(Integer) ? mean.round(half: :even) : mean.round(1, half: :even)
end

# What each column of the results renders: the document with Prawn's API on each engine, with one native block where
# bench/mixed has it, and with Gamba's own API where bench/native has it, untagged then tagged for PDF/UA.
def candidates(document)
  mixed = File.join(__dir__, "mixed", File.basename(document))
  native = File.join(NativeBench::DIRECTORY, File.basename(document))
  columns = Oracle::ENGINES.keys.to_h { |engine| [engine, [engine, document]] }
  columns["gamba_mixed"] = ["gamba", mixed] if File.exist?(mixed)
  return columns unless File.exist?(native)

  columns.merge("gamba_native" => ["gamba", native], "gamba_tagged" => ["gamba", native, "pdf_ua"])
end

# A Williams design: over as many rounds as columns, each column takes each place once and follows each other column
# once (for an even count of columns), so neither a slower moment of the machine nor a heavier neighbour falls
# on one column more than another. Only a multiple of the columns balances all the rounds: 8, the default, balances
# the four columns twice, and gives the invoice's fifth, its native block, each place at least once.
def order(count, round)
  first = [0] + (1...count).map { |step| step.odd? ? (step + 1) / 2 : count - (step / 2) }
  first.map { |index| (index + round) % count }
end

def median_measures(document)
  columns = candidates(document)
  samples_by_column = columns.keys.to_h { |column| [column, []] }
  PROCESSES.times do |round|
    columns.to_a.values_at(*order(columns.size, round)).each { |column, (engine, path, standard)| samples_by_column[column] << measure(engine, path, standard) }
  end
  samples_by_column.transform_values do |samples|
    samples.first.keys.to_h { |name| [name, median(samples.map { |sample| sample[name] })] }
  end
end

results = Dir[File.join(__dir__, "documents/*.rb")].sort.to_h do |document|
  [File.basename(document, ".rb"), median_measures(document)]
end

results.each do |document, measures_by_column|
  measures_by_column.each do |column, measures|
    puts format("%-10s %-12s %s", document, column, measures.map { |name, value| "#{name} #{value}" }.join(", "))
  end
end
File.write(File.expand_path("../docs/benchmarks.json", __dir__), JSON.pretty_generate(ruby: RUBY_DESCRIPTION, iterations: ITERATIONS, processes: PROCESSES, results:) + "\n")
