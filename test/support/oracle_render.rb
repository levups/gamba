# frozen_string_literal: true

# Runs inside one engine's process: `ruby oracle_render.rb OUTPUT_DIRECTORY FILE…`. A file is either a chapter of
# Prawn's manual or a bare document body; each example becomes OUTPUT_DIRECTORY/<name>.pdf, or <name>.error.

require "fileutils"
require "tmpdir"

begin
  require "prawn"
  require "prawn/table"
  require "prawn-svg"
rescue LoadError => exception
  abort "This engine cannot load: #{exception.message}"
end

# SVG samples must not depend on the fonts of the machine rendering them.
Prawn::SVG::FontRegistry.instance_variable_set(:@font_path, [])

# Prawn compresses only when asked: the weight check compares PrawnX with Prawn at its lightest.
Prawn::Document.prepend(Module.new do
  def initialize(options = {}, &)
    super({compress: true}.merge(options), &)
  end
end)

CACHE_DIRECTORY = File.expand_path("../../corpus/cache", __dir__)
MANUAL_DIRECTORY = File.join(CACHE_DIRECTORY, "prawn/manual/")

OracleExample = Data.define(:name, :options, :block)

module Prawn
  module ManualBuilder
    class Example
      def self.generate(filename, &)
        Prawn::Document.generate(filename, &)
      end
    end

    class Chapter
      attr_reader :examples

      def initialize(&)
        @examples = []
        instance_eval(&)
      end

      def title(*)
      end

      def text(*)
      end

      def example(**options, &block)
        @examples << OracleExample.new(name: nil, options:, block:)
      end
    end

    class Peritext
      def initialize(*)
      end

      def examples
        []
      end
    end
  end
end

# An SVG of prawn-svg's samples, drawn across the page, without fetching anything from the web.
def svg_example(path)
  data = File.read(path)
  OracleExample.new(name: "svg-#{File.basename(path, ".svg")}", options: {},
    block: proc { svg data, at: [bounds.left, bounds.top], width: bounds.width, enable_web_requests: false })
end

def examples_from(path)
  return [svg_example(path)] if path.end_with?(".svg")

  source = File.read(path)
    .sub(%r{^require ["']prawn/manual_builder["']$}, "")
    .gsub("Prawn::ManualBuilder::DATADIR", File.join(CACHE_DIRECTORY, "prawn-manual_builder/data").inspect)
    .gsub("Prawn::DATADIR", File.join(CACHE_DIRECTORY, "prawn/data").inspect)
  path = File.expand_path(path)
  name = path.start_with?(MANUAL_DIRECTORY) ? path.delete_prefix(MANUAL_DIRECTORY).delete_suffix(".rb") : File.basename(path, ".rb")
  # prawn-table's manual: whole scripts calling Example.generate(filename), after requiring their helper.
  if source.include?("Example.generate(filename)")
    source = source.sub(/^require File\.expand_path\(.*?\)\)\n/m, "")
    return [OracleExample.new(name: "table-#{name}", options: {standalone: true}, block: proc { eval(source, TOPLEVEL_BINDING, path) })] # rubocop:disable Security/Eval -- Prawn manual examples from the pinned corpus
  end
  return [OracleExample.new(name:, options: {}, block: proc { eval(source, binding, path) })] unless source.include?("ManualBuilder::") # rubocop:disable Security/Eval -- Prawn manual examples from the pinned corpus

  chapter = eval(source, TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval -- Prawn manual examples from the pinned corpus
  chapter.examples.each_with_index.map { |example, index| example.with(name: "#{name}##{index + 1}") }
end

def render(example, output_directory)
  output = File.join(output_directory, example.name.tr("/#", "--"))
  if example.options[:standalone]
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) { example.block.call }
      Dir["#{directory}/*.pdf"].each { FileUtils.mv(_1, "#{output}-#{File.basename(_1)}") }
    end
  else
    document = Prawn::Document.new
    document.stroke_axis if example.options[:axes]
    document.instance_eval(&example.block)
    document.render_file("#{output}.pdf")
  end
rescue StandardError, ScriptError => exception
  File.write("#{output}.error", "#{exception.class}: #{exception.message}\n#{exception.backtrace.first(5).join("\n")}")
end

output_directory, *paths = ARGV
FileUtils.mkdir_p(output_directory)
paths.flat_map { examples_from(_1) }.each { render(_1, output_directory) }
