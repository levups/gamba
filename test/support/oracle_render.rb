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
  OpenSave = Struct.new(:previous, :ext_gstate, :restored)
  # The settings a new page writes, each with its writer, in the order Prawn writes them.
  GRAPHIC_SETTING_WRITERS = {fill_color: :set_fill_color, stroke_color: :set_stroke_color, line_width: :write_line_width,
                             cap_style: :write_stroke_cap_style, join_style: :write_stroke_join_style, dash: :write_stroke_dash}.freeze
  # PrawnX's PDF::Core::GraphicState::DEFAULT_TEXT_STATE, which Prawn's pdf-core lacks.
  DEFAULT_TEXT_STATE = {text_rendering_mode: :fill, character_spacing: 0, word_spacing: 0, horizontal_text_scaling: 100, rise: 0}.freeze

  class << self
    attr_accessor :taken
  end
end

# ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK: like PrawnX, a page break reopens the open transparent and blend_mode blocks,
# and a block saved on an earlier page writes back, once it ends, the settings in effect before it. A new page, a block
# ending on a later page and go_to_page write back the text state in effect, and go_to_page closes the states left on
# its page by blocks that ended on another one. Where any of these happened,
# <name>.switched: only there may PrawnX differ from plain Prawn (prawn_switch in test/divergences.yml).
if ENV["ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK"]
  # Each state records the text state written in it, as PrawnX's does.
  PDF::Core::GraphicState.prepend(Module.new do
    attr_writer :text_state
    # The save that opened this state, or that it was reopened for, as PrawnX records it; a copy has none.
    attr_accessor :save

    def text_state
      @text_state || PrawnSwitch::DEFAULT_TEXT_STATE
    end

    def initialize_copy(other)
      super
      @text_state = other.text_state
    end
  end)

  Prawn::Document.prepend(Module.new do
    PrawnSwitch::DEFAULT_TEXT_STATE.each_key do |setting|
      define_method(:"update_#{setting}_state") do
        super()
        state = renderer.graphic_stack.current_state
        state.text_state = state.text_state.merge(setting => public_send(setting)).freeze
      end
    end

    # The block runs here, not in Prawn's renderer, whose restore would bypass this module's.
    def save_graphics_state(graphic_state = nil)
      previous = renderer.graphic_stack.current_state
      open_save = PrawnSwitch::OpenSave.new(previous, nil, false)
      open_saves << open_save
      super(graphic_state, &nil)
      renderer.graphic_stack.current_state.save = open_save
      renderer.graphic_stack.current_state.text_state = previous&.text_state if graphic_state
      return unless block_given?

      yield
      restore_graphics_state
    end

    def restore_graphics_state
      open_save = open_saves.pop
      open_save&.restored = true
      super
      return unless open_save && !renderer.graphic_stack.current_state.equal?(open_save.previous)

      resume_graphic_settings(open_save.previous)
      resume_text_state
    end

    def transparent(opacity, stroke_opacity = opacity)
      super do
        open_saves.last.ext_gstate = -> { opacity_dictionary_name(opacity.clamp(0.0, 1.0), stroke_opacity.clamp(0.0, 1.0)) }
        yield
      end
    end

    def blend_mode(blend_mode = :Normal)
      return super unless block_given?

      super do
        open_saves.last.ext_gstate = -> { blend_mode_dictionary_name(blend_mode) }
        yield
      end
    end

    # Only start_new_page calls it, once the new page's state is a copy of the last page's.
    def use_graphic_settings(*)
      renderer.graphic_stack.current_state&.text_state = PrawnSwitch::DEFAULT_TEXT_STATE
      super
      resume_text_state
    end

    # Content drawn on a page again, or flowing onto one that exists, is laid out with the text state in effect.
    # There, it is drawn outside the blocks that ended on another page.
    def go_to_page(*)
      super
      while renderer.graphic_stack.current_state&.save&.restored
        PrawnSwitch.taken = true
        renderer.restore_graphics_state
      end
      resume_text_state
    end

    def start_new_page(options = {})
      super
      return if options[:orphan] || open_saves.none?(&:ext_gstate)

      PrawnSwitch.taken = true
      outermost, *inner = open_saves
      renderer.graphic_stack.current_state.save = outermost
      renderer.add_content("/#{outermost.ext_gstate.call} gs") if outermost.ext_gstate
      inner.each do |open_save|
        renderer.graphic_stack.save_graphic_state
        renderer.graphic_stack.current_state.save = open_save
        renderer.add_content("q")
        renderer.add_content("/#{open_save.ext_gstate.call} gs") if open_save.ext_gstate
      end
    end

    private

    def open_saves
      @open_saves ||= []
    end

    def resume_graphic_settings(previous)
      previous ||= PDF::Core::GraphicState.new
      current = renderer.graphic_stack.current_state || PDF::Core::GraphicState.new
      differing = PrawnSwitch::GRAPHIC_SETTING_WRITERS.reject { |setting, _writer| current.public_send(setting) == previous.public_send(setting) }
      return if differing.empty?

      PrawnSwitch.taken = true
      state = graphic_state
      PrawnSwitch::GRAPHIC_SETTING_WRITERS.each_key { |setting| state.public_send(:"#{setting}=", previous.public_send(setting).dup) }
      differing.each_value { |writer| send(writer) }
    end

    def resume_text_state
      current = renderer.graphic_stack.current_state&.text_state || PrawnSwitch::DEFAULT_TEXT_STATE
      current.each do |setting, written|
        value = public_send(setting)
        next if value == written || value == :unknown

        PrawnSwitch.taken = true
        send(:"update_#{setting}_state")
      end
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
