# frozen_string_literal: true

# Loaded with RUBYOPT=-r…/capture_pdfs.rb into an app's test run: every PDF a test renders is written to
# GAMBA_CAPTURE_DIRECTORY, named after the test, so the same run under Prawn and under Gamba can be compared.
require "fileutils"

module GambaCapture
  DIRECTORY = ENV.fetch("GAMBA_CAPTURE_DIRECTORY")
  @count_by_test = Hash.new(0)

  class << self
    attr_accessor :current_test

    def write(pdf)
      name = (current_test || "outside_a_test").gsub(/[^\w-]+/, "_")
      index = (@count_by_test[name] += 1)
      FileUtils.mkdir_p(DIRECTORY)
      File.binwrite(File.join(DIRECTORY, "#{name}-#{index}.pdf"), pdf)
    end
  end

  module Render
    def render(*arguments)
      pdf = super
      GambaCapture.write(pdf)
      pdf
    end
  end

  module NameTests
    def before_setup
      GambaCapture.current_test = "#{self.class.name}##{name}"
      super
    end
  end
end

MODULE_NAME = Module.instance_method(:name)

TracePoint.new(:end) do |trace|
  name = MODULE_NAME.bind_call(trace.self)
  if name == "Prawn::Document"
    trace.self.prepend(GambaCapture::Render) unless trace.self.ancestors.include?(GambaCapture::Render)
  end
  if defined?(Minitest::Test) && trace.self == Minitest::Test && !Minitest::Test <= GambaCapture::NameTests
    Minitest::Test.prepend(GambaCapture::NameTests)
  end
end.enable
