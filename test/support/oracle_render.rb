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

# ORACLE_PAST_GRAPHIC_STATE_CRASH: like PrawnX, Prawn lets a restore end without anything to close on an emptied
# stack while a save is still open, to tell what a document raises further on.
if ENV["ORACLE_PAST_GRAPHIC_STATE_CRASH"]
  PDF::Core::Renderer.prepend(Module.new do
    def save_graphics_state(*)
      @unrestored_graphics_states = (@unrestored_graphics_states || 0) + 1
      super
    end

    def restore_graphics_state
      saved = @unrestored_graphics_states.to_i.positive?
      @unrestored_graphics_states -= 1 if saved
      super unless saved && graphic_stack.empty?
    end
  end)
end

# Whether a switch below changed what Prawn draws for the example being rendered.
module PrawnSwitch
  class << self
    attr_accessor :taken
  end
end

# ORACLE_REOPEN_TRANSPARENCY: like PrawnX, a page break reopens the blocks still open when one of them is transparent,
# the outermost in the new page's own state, each with its opacity. An example where it did is marked <name>.switched:
# only there may PrawnX differ from Prawn without this switch (prawn_switch in test/divergences.yml).
if ENV["ORACLE_REOPEN_TRANSPARENCY"]
  Prawn::Document.prepend(Module.new do
    def save_graphics_state(*)
      open_opacities << nil
      return super unless block_given?

      super.tap { open_opacities.pop }
    end

    def restore_graphics_state
      open_opacities.pop
      super
    end

    def transparent(opacity, stroke_opacity = opacity)
      super do
        open_opacities[-1] = [opacity.clamp(0.0, 1.0), stroke_opacity.clamp(0.0, 1.0)]
        yield
      end
    end

    def start_new_page(options = {})
      super
      return if options[:orphan] || open_opacities.none?

      PrawnSwitch.taken = true
      outermost, *inner = open_opacities
      renderer.add_content("/#{opacity_dictionary_name(*outermost)} gs") if outermost
      inner.each do |opacities|
        renderer.graphic_stack.save_graphic_state
        renderer.add_content("q")
        renderer.add_content("/#{opacity_dictionary_name(*opacities)} gs") if opacities
      end
    end

    private

    def open_opacities
      @open_opacities ||= []
    end
  end)
end

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
  PrawnSwitch.taken = false
  if example.options[:standalone]
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) { example.block.call }
      Dir["#{directory}/*.pdf"].each { |path| FileUtils.mv(path, "#{output}-#{File.basename(path)}") }
    end
  else
    document = Prawn::Document.new
    document.stroke_axis if example.options[:axes]
    document.instance_eval(&example.block)
    document.render_file("#{output}.pdf")
  end
rescue StandardError, ScriptError => exception
  File.write("#{output}.error", "#{exception.class}: #{exception.message}\n#{exception.backtrace.first(5).join("\n")}")
ensure
  FileUtils.touch("#{output}.switched") if PrawnSwitch.taken
end

output_directory, *paths = ARGV
FileUtils.mkdir_p(output_directory)
paths.flat_map { examples_from(_1) }.each { render(_1, output_directory) }
