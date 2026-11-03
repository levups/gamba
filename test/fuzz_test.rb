# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/fuzz_documents"

# Random documents from a seed, rendered by Prawn and by PrawnX: FUZZ_SEED and FUZZ_CASES choose them, and a
# failure names the file holding the document, kept in tmp/fuzz to reproduce it.
class FuzzTest < Minitest::Test
  SEED = Integer(ENV.fetch("FUZZ_SEED", "20261101"))
  CASES = Integer(ENV.fetch("FUZZ_CASES", "60"))
  DIRECTORY = File.join(Oracle::ROOT, "tmp/fuzz")

  def test_random_documents_render_like_prawn
    skip CORPUS_MISSING_MESSAGE if Oracle.manual_chapters.empty?
    skip "FUZZ_CASES is 0" if CASES.zero?

    FileUtils.rm_rf(DIRECTORY)
    FileUtils.mkdir_p(File.join(DIRECTORY, "documents"))
    generator = FuzzDocuments.new(SEED)
    paths = Array.new(CASES) do |index|
      File.join(DIRECTORY, "documents", format("fuzz_%04d.rb", index)).tap { File.write(it, generator.document) }
    end
    reference = Oracle.render("prawn", paths, File.join(DIRECTORY, "prawn"))
    candidate = Oracle.render("prawnx", paths, File.join(DIRECTORY, "prawnx"))

    failures = Oracle.example_names(reference).filter_map do |name|
      differences = Oracle.differences(reference, candidate, name)
      "#{DIRECTORY}/documents/#{name}.rb: #{differences.first}" unless differences.empty?
    end
    assert_empty failures, "seed #{SEED}: #{failures.size} of #{CASES} documents differ"
  end
end
