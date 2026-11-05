# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "prawn-svg"
require "yaml"

# Gamba answers every call Prawn 2.5, prawn-table and prawn-svg accept on the methods of its contract:
# test/contract/prawn-*.yml list them, test/contract/decisions.yml settles Prawn's Experimental and ungrouped ones.
class ContractTest < Minitest::Test
  API = Dir[File.join(__dir__, "contract/prawn-*.yml")].sort.map { YAML.load_file(_1) }.inject(:merge)
  DECISIONS = YAML.load_file(File.join(__dir__, "contract/decisions.yml"), aliases: true)
  ALWAYS_IN_GROUPS = ["Stable API", "Stable Attributes"].freeze
  ALWAYS_OUT_GROUPS = ["Extension API", "Extension Attributes"].freeze

  def self.decision_for(class_name, method_name, description)
    return false if description["yard_private"] || ALWAYS_OUT_GROUPS.include?(description["group"])
    return true if ALWAYS_IN_GROUPS.include?(description["group"])

    DECISIONS.dig(class_name, method_name)
  end

  API.each do |class_name, methods|
    methods.each do |method_name, description|
      decision = decision_for(class_name, method_name, description)
      next unless decision == true

      define_method("test_#{class_name}#{method_name}") do
        method = gamba_method(class_name, method_name)
        skip "not written yet" unless method

        assert_accepts_calls_of description.fetch("parameters"), method
      end
    end
  end

  def test_every_experimental_or_ungrouped_method_is_decided
    undecided = API.flat_map do |class_name, methods|
      methods.filter_map { |method_name, description| "#{class_name}#{method_name}" if self.class.decision_for(class_name, method_name, description).nil? }
    end
    assert_empty undecided, "decide each one in test/contract/decisions.yml"
  end

  def test_every_decision_names_a_method_of_the_contract
    stale = DECISIONS.flat_map { |class_name, methods| methods.keys.reject { API.dig(class_name, _1) }.map { "#{class_name}#{_1}" } }
    assert_empty stale
  end

  private

  def gamba_method(class_name, method_name)
    klass = Object.const_get(class_name) if Object.const_defined?(class_name)
    return unless klass

    name = method_name.delete_prefix("#").delete_prefix(".").to_sym
    if method_name.start_with?(".")
      klass.method(name) if klass.respond_to?(name)
    elsif klass.public_method_defined?(name)
      klass.instance_method(name)
    end
  end

  # Every argument list Prawn's signature takes must be one Gamba's takes too.
  def assert_accepts_calls_of(reference_parameters, method)
    reference = reference_parameters.map { _1.split.then { |kind, name| [kind.to_sym, name&.to_sym] } }
    candidate = method.parameters
    reference_required = reference.count { _1.first == :req }
    reference_positional = reference.count { %i[req opt].include?(_1.first) }
    candidate_required = candidate.count { _1.first == :req }
    candidate_positional = candidate.count { %i[req opt].include?(_1.first) }
    candidate_rest = candidate.any? { _1.first == :rest }
    candidate_keyrest = candidate.any? { _1.first == :keyrest }

    assert_operator candidate_required, :<=, reference_required, "#{method.name} requires more positional arguments than Prawn"
    assert candidate_rest || candidate_positional >= reference_positional, "#{method.name} takes fewer positional arguments than Prawn"
    assert candidate_rest, "#{method.name} lacks Prawn's *rest" if reference.any? { _1.first == :rest }
    assert candidate_keyrest, "#{method.name} lacks Prawn's **options" if reference.any? { _1.first == :keyrest }
    reference.select { %i[key keyreq].include?(_1.first) }.each do |_kind, name|
      assert candidate_keyrest || candidate.any? { |kind, candidate_name| %i[key keyreq].include?(kind) && candidate_name == name }, "#{method.name} lacks keyword #{name}:"
    end
    candidate.select { _1.first == :keyreq }.each do |_kind, name|
      assert reference.include?([:keyreq, name]), "#{method.name} requires keyword #{name}:, Prawn does not"
    end
  end
end
