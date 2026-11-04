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
  # Prawn crashes PrawnX fixes, from test/divergences.yml: where PrawnX renders instead, its PDF must be valid.
  FIXED_PRAWN_CRASHES = YAML.load_file(File.join(__dir__, "divergences.yml")).filter_map { _1["prawn_raises"] }.freeze

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

    failures = Oracle.example_names(reference).filter_map do |name|
      prawn_error = Oracle.error_class(reference, name)
      # Where PrawnX still raises the same error as Prawn, the usual comparison applies.
      differences = if FIXED_PRAWN_CRASHES.include?(prawn_error) && !Oracle.error_class(candidate, name)
        Oracle.fixed_crash_differences(reference, candidate, name, prawn_error)
      else
        Oracle.differences(reference, candidate, name)
      end
      "#{DIRECTORY}/documents/#{name}.rb: #{differences.first}" unless differences.empty?
    end
    assert_empty failures, "seed #{SEED}: #{failures.size} of #{CASES} documents differ"
  end
end
