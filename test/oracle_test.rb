# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# Every example of Prawn's manual, rendered by Prawn and by ORACLE_CANDIDATE (Gamba by default). The examples in
# test/oracle_passing.txt must stay identical; any other one that becomes identical must be added there.
class OracleTest < Minitest::Test
  PASSING_LIST = File.join(__dir__, "oracle_passing.txt")
  DIVERGENCES = YAML.load_file(File.join(__dir__, "divergences.yml"))
  DIVERGENCE_BY_EXAMPLE = DIVERGENCES.flat_map { |divergence| divergence.fetch("examples").map { [_1, divergence] } }.to_h
  CANDIDATE = ENV.fetch("ORACLE_CANDIDATE", "gamba")
  OUTPUT_DIRECTORY = File.join(Oracle::ROOT, "tmp/oracle")

  if Oracle.manual_chapters.empty?
    define_method(:test_corpus) { skip CORPUS_MISSING_MESSAGE }
  else
    reference = Oracle.render("prawn", Oracle.example_files, File.join(OUTPUT_DIRECTORY, "reference"))
    raise "Prawn cannot render the manual: #{reference.failure}" if reference.failure

    candidate = Oracle.render(CANDIDATE, Oracle.example_files, File.join(OUTPUT_DIRECTORY, CANDIDATE))
    # Prawn fixing a bug as Gamba does, through a switch of test/support/oracle_render.rb (prawn_switch), for the
    # examples of the bugs it fixes only.
    names_by_switch = DIVERGENCES.select { _1.key?("prawn_switch") }.group_by { _1["prawn_switch"] }
      .transform_values { |divergences| divergences.flat_map { _1["examples"] } }
    switched_by_example = names_by_switch.flat_map do |switch, names|
      paths = names.map { File.join(Oracle::EXAMPLES_DIRECTORY, "#{_1}.rb") }
      switched = Oracle.render("prawn", paths, File.join(OUTPUT_DIRECTORY, switch.downcase), switch => "1")
      raise "Prawn cannot render with #{switch}: #{switched.failure}" if switched.failure
      names.map { [_1, switched] }
    end.to_h
    passing_names = File.foreach(PASSING_LIST, chomp: true).reject { |line| line.empty? || line.start_with?("#") }
    passing_names = Oracle.example_names(reference) if CANDIDATE == "prawn"

    Oracle.example_names(reference).each do |name|
      define_method("test_#{name}") do
        divergence = DIVERGENCE_BY_EXAMPLE[name]
        skip "Prawn bug, see test/divergences.yml: #{divergence["bug"]}" if CANDIDATE == "prawn" && divergence

        differences = if divergence&.key?("prawn_raises")
          Oracle.fixed_crash_differences(reference, candidate, name, divergence["prawn_raises"])
        elsif (switched = switched_by_example[name])
          assert Oracle.switched?(switched, name), "#{divergence["prawn_switch"]} no longer changes how Prawn draws #{name}"
          Oracle.differences(switched, candidate, name)
        else
          Oracle.differences(reference, candidate, name)
        end
        expected_differences = divergence&.fetch("differences", nil) || []
        if passing_names.include?(name)
          assert expected?(differences, expected_differences),
            "#{name} no longer matches Prawn, but for test/divergences.yml: #{differences.inspect}"
        elsif expected?(differences, expected_differences)
          flunk "#{name} now renders as expected: add it to test/oracle_passing.txt"
        else
          skip differences.first
        end
      end
    end

    define_method(:test_every_divergence_still_shows_in_prawn) do
      DIVERGENCE_BY_EXAMPLE.each do |name, divergence|
        assert_includes Oracle.example_names(reference), name, "test/divergences.yml names an unknown example"
        if (switched = switched_by_example[name])
          refute_empty Oracle.differences(switched, reference, name), "Prawn no longer shows the bug in #{name}"
        end
        next unless divergence["prawn_writes_invalid_pdf"]

        refute_nil Oracle.invalidity(File.join(reference.directory, "#{name}.pdf")), "Prawn no longer shows the bug in #{name}"
      end
    end

    define_method(:test_passing_list_names_existing_examples) do
      assert_empty passing_names - Oracle.example_names(reference), "unknown examples in test/oracle_passing.txt"
    end
  end

  # A difference declared between slashes is a pattern: pixel counts vary with the mutool version.
  def expected?(differences, expected_differences)
    differences.size == expected_differences.size &&
      differences.zip(expected_differences).all? do |difference, expected|
        (expected.start_with?("/") && expected.end_with?("/")) ? difference.match?(Regexp.new(expected[1..-2])) : difference == expected
      end
  end
end
