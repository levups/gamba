# frozen_string_literal: true

# Loaded with RUBYOPT=-r…/capture_pdfs.rb into an app's test run: every PDF a test renders is written to
# GAMBA_CAPTURE_DIRECTORY, named after the test, so the same run under Prawn and under Gamba can be compared.
# Run as `ruby capture_pdfs.rb tmp/prawn tmp/gamba`, it compares them with the checks of gamba/minitest and
# gamba/rspec, and exits 1 when a PDF differs.
require "fileutils"

if $PROGRAM_NAME == __FILE__
  require_relative "../lib/gamba/pdf_check"

  expected_directory, actual_directory = ARGV
  abort "usage: ruby #{$PROGRAM_NAME} PRAWN_DIRECTORY GAMBA_DIRECTORY" unless actual_directory

  names = (Dir.children(expected_directory) | Dir.children(actual_directory)).grep(/\.pdf\z/).sort
  differing = names.count do |name|
    expected = File.join(expected_directory, name)
    actual = File.join(actual_directory, name)
    differences = if !File.exist?(actual) then ["missing from #{actual_directory}"]
    elsif !File.exist?(expected) then ["missing from #{expected_directory}"]
    else Gamba::PdfCheck.page_differences(expected, actual)
    end
    puts "#{name}: #{differences.join("; ")}" unless differences.empty?
    !differences.empty?
  end
  puts "#{names.size} PDFs, #{differing} differing"
  exit(differing.zero? ? 0 : 1)
end

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
