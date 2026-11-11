# frozen_string_literal: true

require_relative "test_helper"
require "prawn"
require "yaml"

# Gamba's own API is guarded like Prawn's: test/contract/gamba.yml lists every public method and its signature.
class NativeContractTest < Minitest::Test
  API = YAML.load_file(File.join(__dir__, "contract/gamba.yml"))
  # Classes whose every public method is in the contract; Prawn::Document only lists what Gamba adds to Prawn's.
  WHOLLY_LISTED = {"Gamba" => :singleton, "Gamba::Document" => :instance}.freeze

  API.each do |class_name, methods|
    methods.each do |method_name, parameters|
      define_method("test_#{class_name}#{method_name}") do
        assert_equal parameters, signature(class_name, method_name)
      end
    end
  end

  def test_every_public_method_is_in_the_contract
    WHOLLY_LISTED.each do |class_name, kind|
      owner = Object.const_get(class_name)
      public_names = (kind == :singleton) ? owner.singleton_methods(false).map { ".#{_1}" } : (owner.public_instance_methods - Object.public_instance_methods).map { "##{_1}" }

      assert_empty public_names - API.fetch(class_name).keys, "list each one in test/contract/gamba.yml"
    end
  end

  private

  def signature(class_name, method_name)
    owner = Object.const_get(class_name)
    name = method_name.delete_prefix("#").delete_prefix(".").to_sym
    method = method_name.start_with?(".") ? owner.method(name) : owner.instance_method(name)
    method.parameters.map { |kind, parameter_name| [kind, parameter_name].compact.join(" ") }
  end
end
