# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fuzz_documents"
require "yaml"

# Random documents from a seed, rendered by Prawn and by PrawnX: FUZZ_SEED and FUZZ_CASES choose them, and a
# failure names the file holding the document, kept in tmp/fuzz to reproduce it.
class FuzzTest < Minitest::Test
  SEED = Integer(ENV.fetch("FUZZ_SEED", "20261101"))
  CASES = Integer(ENV.fetch("FUZZ_CASES", "60"))
  DIRECTORY = File.join(Oracle::ROOT, "tmp/fuzz")
  # Prawn crashes PrawnX fixes, from test/divergences.yml: PrawnX must never raise them, but render a valid PDF or
  # raise what Prawn raises once past the crash.
  DIVERGENCES = YAML.load_file(File.join(__dir__, "divergences.yml"))
  FIXED_PRAWN_CRASHES = DIVERGENCES.filter_map { _1["prawn_raises"] }.freeze
  # Switches of test/support/oracle_render.rb making Prawn fix a bug as PrawnX does, from test/divergences.yml.
  PRAWN_SWITCHES = DIVERGENCES.filter_map { _1["prawn_switch"] }.to_h { [_1, "1"] }.freeze

  def test_random_documents_render_like_prawn
    skip CORPUS_MISSING_MESSAGE if Oracle.manual_chapters.empty?
    skip "FUZZ_CASES is 0" if CASES.zero?

    FileUtils.rm_rf(DIRECTORY)
    FileUtils.mkdir_p(File.join(DIRECTORY, "documents"))
    generator = FuzzDocuments.new(SEED)
    paths = Array.new(CASES) do |index|
      File.join(DIRECTORY, "documents", format("fuzz_%04d.rb", index)).tap { File.write(_1, generator.document) }
    end
    reference = Oracle.render("prawn", paths, File.join(DIRECTORY, "prawn"))
    candidate = Oracle.render("prawnx", paths, File.join(DIRECTORY, "prawnx"))

    past_crash = past_fixed_crashes(reference, candidate, paths)
    differences_by_name = Oracle.example_names(reference).to_h do |name|
      prawn_error = Oracle.error_class(reference, name)
      differences = if past_crash && Oracle.error_class(past_crash, name)
        # PrawnX goes past Prawn's crash and raises further on: so must Prawn once past it.
        Oracle.differences(past_crash, candidate, name)
      elsif FIXED_PRAWN_CRASHES.include?(prawn_error)
        Oracle.fixed_crash_differences(reference, candidate, name, prawn_error)
      else
        Oracle.differences(reference, candidate, name)
      end
      [name, differences]
    end
    switched = switched_prawn(reference, differences_by_name)
    failures = differences_by_name.filter_map do |name, differences|
      # Where Prawn fixes the bug once switched, PrawnX must match that Prawn exactly.
      differences = Oracle.differences(switched, candidate, name) if switched && Oracle.switched?(switched, name)
      "#{DIRECTORY}/documents/#{name}.rb: #{differences.first}" unless differences.empty?
    end
    assert_empty failures, "seed #{SEED}: #{failures.size} of #{CASES} documents differ"
  end

  private

  # Documents where Prawn raises a crash PrawnX fixes and PrawnX raises another error, rendered again by Prawn going
  # past that crash, with the switches of test/divergences.yml; nil when there are none.
  def past_fixed_crashes(reference, candidate, paths)
    crashed = paths.select do |path|
      name = File.basename(path, ".rb")
      prawn_error = Oracle.error_class(reference, name)
      candidate_error = Oracle.error_class(candidate, name)
      FIXED_PRAWN_CRASHES.include?(prawn_error) && candidate_error && candidate_error != prawn_error
    end
    return if crashed.empty?

    Oracle.render("prawn", crashed, File.join(DIRECTORY, "prawn-past-crash"), {"ORACLE_PAST_GRAPHIC_STATE_CRASH" => "1", **PRAWN_SWITCHES})
  end

  # Documents PrawnX draws differently from Prawn, without a crash it fixes, rendered again by Prawn with the switches
  # of test/divergences.yml; nil when there are none.
  def switched_prawn(reference, differences_by_name)
    differing = differences_by_name.filter_map do |name, differences|
      File.join(DIRECTORY, "documents", "#{name}.rb") unless differences.empty? || FIXED_PRAWN_CRASHES.include?(Oracle.error_class(reference, name))
    end
    return if differing.empty? || PRAWN_SWITCHES.empty?

    Oracle.render("prawn", differing, File.join(DIRECTORY, "prawn-switched"), PRAWN_SWITCHES)
  end
end
