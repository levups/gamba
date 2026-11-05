# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/corrupt_inputs"
require "prawn"
require "timeout"

# Images and fonts may come from users: corrupted ones must render or fail with an error Gamba names, never crash
# inside a parser, hang or exhaust memory. INPUT_FUZZ_SEED and INPUT_FUZZ_CASES choose them.
class InputFuzzTest < Minitest::Test
  SEED = Integer(ENV.fetch("INPUT_FUZZ_SEED", "20261102"))
  CASES = Integer(ENV.fetch("INPUT_FUZZ_CASES", "200"))
  SECONDS_PER_CASE = 10
  EXPECTED_ERRORS = [
    Prawn::Errors::UnsupportedImageType, Prawn::Images::JPG::FormatError, Gamba::TrueType::Error,
    Prawn::Errors::IncompatibleStringEncoding
  ].freeze
  DATA_DIRECTORY = File.join(Oracle::ROOT, "corpus/cache/prawn/data")

  def test_corrupted_images_and_fonts_fail_cleanly
    skip CORPUS_MISSING_MESSAGE unless File.directory?(DATA_DIRECTORY)

    samples = Dir["#{DATA_DIRECTORY}/images/*.{png,jpg}"] + Dir["#{DATA_DIRECTORY}/fonts/*.{ttf,otf}"]
    corrupter = CorruptInputs.new(SEED)
    picker = Random.new(SEED)
    failures = []
    Dir.mktmpdir do |directory|
      CASES.times do |index|
        sample = samples.sample(random: picker)
        path = File.join(directory, "case_#{index}#{File.extname(sample)}")
        File.binwrite(path, corrupter.corrupt(File.binread(sample)))
        failure = unclean_failure(path)
        failures << "case #{index} from #{File.basename(sample)}: #{failure}" if failure
      end
    end
    assert_empty failures, "seed #{SEED}"
  end

  private

  def unclean_failure(path)
    Timeout.timeout(SECONDS_PER_CASE) do
      Prawn::Document.new do
        if path.end_with?(".png", ".jpg")
          image path, width: 100
        else
          font path
          text "Avocado, café €"
        end
      end.render
    end
    nil
  rescue *EXPECTED_ERRORS
    nil
  rescue Timeout::Error
    "took more than #{SECONDS_PER_CASE} s"
  rescue StandardError, NoMemoryError, SystemStackError => exception
    # Prawn's own error for a JPEG of 2 or 5+ channels, kept as is.
    return if exception.instance_of?(ArgumentError) && exception.message == "JPG uses an unsupported number of channels"

    "#{exception.class}: #{exception.message[0, 100]} at #{exception.backtrace.first}"
  end
end
