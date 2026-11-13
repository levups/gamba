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

# Prawn compresses only when asked: the weight check compares Gamba with Prawn at its lightest.
Prawn::Document.prepend(Module.new do
  def initialize(options = {}, &)
    super({compress: true}.merge(options), &)
  end
end)

# ORACLE_PAST_GRAPHIC_STATE_CRASH: like Gamba, Prawn lets a restore end without anything to close on an emptied
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
  # The settings a block ending on a later page writes back, each with its writer, as Gamba's do.
  GRAPHIC_SETTING_WRITERS = {fill_paint: :write_fill_paint, stroke_paint: :write_stroke_paint, line_width: :write_line_width,
                             cap_style: :write_stroke_cap_style, join_style: :write_stroke_join_style, dash: :write_stroke_dash,
                             blend_mode: :write_blend_mode}.freeze
  RESUMED_STATE = %i[fill_color fill_pattern stroke_color stroke_pattern line_width cap_style join_style dash blend_mode].freeze
  # Gamba's PDF::Core::GraphicState::DEFAULT_TEXT_STATE, which Prawn's pdf-core lacks.
  DEFAULT_TEXT_STATE = {text_rendering_mode: :fill, character_spacing: 0, word_spacing: 0, horizontal_text_scaling: 100, rise: 0}.freeze

  class << self
    attr_accessor :taken
  end
end

# ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK: like Gamba, a page break reopens the open transparent and blend_mode blocks,
# then sets the blend mode in effect again, a new page paints with the gradients in effect, and a block saved on an
# earlier page writes back, once it ends, the settings in effect before it. A new page, a block ending on a later page
# and go_to_page write back the text state in effect, and go_to_page closes the states left on its page by blocks that
# ended on another one, then reopens on top of the page's own state the open transparent and blend_mode blocks saved
# on another page; text flowing onto a page that exists writes back there the graphic settings in effect, as a new
# page does. Where any of these happened,
# <name>.switched: only there may Gamba differ from plain Prawn (prawn_switch in test/divergences.yml).
if ENV["ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK"]
  # Each state records, by name, the pattern painting in place of each colour and the blend mode, and the text state
  # written in it, as Gamba's does.
  PDF::Core::GraphicState.prepend(Module.new do
    attr_accessor :fill_pattern, :stroke_pattern, :blend_mode
    attr_writer :text_state
    # The save that opened this state, or that it was reopened for, as Gamba records it; a copy has none.
    attr_accessor :save

    def text_state
      @text_state || PrawnSwitch::DEFAULT_TEXT_STATE
    end

    def initialize_copy(other)
      super
      @fill_pattern = other.fill_pattern
      @stroke_pattern = other.stroke_pattern
      @blend_mode = other.blend_mode
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
      name = "BM#{Array(blend_mode).join}"
      return super.tap { record_blend_mode(name) } unless block_given?

      super do
        record_blend_mode(name)
        open_saves.last.ext_gstate = -> { blend_mode_dictionary_name(blend_mode) }
        yield
      end
    end

    # Its ExtGState sets the blend mode back to Normal.
    def soft_mask(*)
      super
      renderer.graphic_stack.current_state.blend_mode = nil
    end

    # A pattern the page's resources hold is recorded, to paint with on the next page.
    def set_color(type, color, options = {})
      super
      reference = page.dictionary.data[:Resources]&.dig(:Pattern, color) if options[:pattern]
      pattern_references[color] = reference if reference
      state = renderer.graphic_stack.current_state
      state.public_send(:"#{type}_pattern=", (color if reference)) if reference || state.public_send(:"#{type}_pattern")
    end

    def set_gradient(type, *, **)
      super
      name = "SP#{gradient_registry_key(parse_gradient_arguments(*, **))}"
      pattern_references[name] = page.resources[:Pattern][name]
      renderer.graphic_stack.current_state.public_send(:"#{type}_pattern=", name)
    end

    # Only start_new_page calls it, once the new page's state is a copy of the last page's: Prawn's, but a gradient
    # stays the fill or stroke, and the blend mode waits for the blocks to reopen.
    def use_graphic_settings(override_settings = false)
      state = renderer.graphic_stack.current_state
      @last_blend_mode = state.blend_mode
      state.blend_mode = nil
      state.text_state = PrawnSwitch::DEFAULT_TEXT_STATE
      write_fill_paint if state.fill_pattern || current_fill_color != "000000" || override_settings
      write_stroke_paint if state.stroke_pattern || current_stroke_color != "000000" || override_settings
      write_line_width if line_width != 1 || override_settings
      write_stroke_cap_style if cap_style != :butt || override_settings
      write_stroke_join_style if join_style != :miter || override_settings
      write_stroke_dash if dashed? || override_settings
      resume_text_state
    end

    # Content drawn on a page again, or flowing onto one that exists, is laid out with the text state in effect.
    # There, it is drawn outside the blocks that ended on another page, and inside those still open.
    def go_to_page(*)
      super
      closed = nil
      while (state = renderer.graphic_stack.current_state)&.save&.restored
        PrawnSwitch.taken = true
        closed = state
        renderer.restore_graphics_state
      end
      if closed
        renderer.graphic_state
        resume_graphic_settings(closed.save.previous)
      end
      reopen_ext_gstate_blocks_on_existing_page
      resume_text_state
    end

    def start_new_page(options = {})
      super
      return if options[:orphan]

      header_blend_mode = renderer.graphic_stack.current_state&.blend_mode
      reopen_ext_gstate_blocks
      return if header_blend_mode || renderer.graphic_stack.current_state&.blend_mode == @last_blend_mode

      PrawnSwitch.taken = true
      write_blend_mode(@last_blend_mode)
    end

    private

    # Text flowing onto a page that exists goes on with the settings in effect, as on a new page.
    def flow_onto_page(page_number)
      carried = renderer.graphic_stack.current_state
      go_to_page(page_number)
      resume_graphic_settings(carried)
    end

    def open_saves
      @open_saves ||= []
    end

    def pattern_references
      @pattern_references ||= {}
    end

    def reopen_ext_gstate_blocks
      return if open_saves.empty?

      outermost, *inner = open_saves
      renderer.graphic_stack.current_state.save = outermost
      return if open_saves.none?(&:ext_gstate)

      PrawnSwitch.taken = true
      write_ext_gstate(outermost.ext_gstate.call) if outermost.ext_gstate
      inner.each { reopen_graphics_state(_1) }
    end

    def reopen_ext_gstate_blocks_on_existing_page
      return if open_saves.none?(&:ext_gstate)

      saves_on_page = renderer.graphic_stack.stack.filter_map(&:save)
      saved_elsewhere = open_saves.reject { |open_save| saves_on_page.any? { _1.equal?(open_save) } }
      return if saved_elsewhere.none?(&:ext_gstate)

      PrawnSwitch.taken = true
      renderer.graphic_state
      saved_elsewhere.each { reopen_graphics_state(_1) }
    end

    def reopen_graphics_state(open_save)
      renderer.graphic_stack.save_graphic_state
      renderer.graphic_stack.current_state.save = open_save
      renderer.add_content("q")
      write_ext_gstate(open_save.ext_gstate.call) if open_save.ext_gstate
    end

    def write_ext_gstate(name)
      renderer.add_content("/#{name} gs")
      record_blend_mode(name) if name.start_with?("BM")
    end

    def record_blend_mode(name)
      renderer.graphic_stack.current_state.blend_mode = (name == "BMNormal") ? nil : name
    end

    # The blend mode named, nil for Normal, set as it was first: registered already, but on this page.
    def write_blend_mode(name = renderer.graphic_stack.current_state.blend_mode)
      key = name&.delete_prefix("BM") || "Normal"
      write_ext_gstate(blend_mode_dictionary_name((key == "Normal") ? :Normal : key))
    end

    def write_fill_paint
      (name = renderer.graphic_stack.current_state.fill_pattern) ? write_pattern(:fill, name) : set_fill_color
    end

    def write_stroke_paint
      (name = renderer.graphic_stack.current_state.stroke_pattern) ? write_pattern(:stroke, name) : set_stroke_color
    end

    def write_pattern(type, name)
      PrawnSwitch.taken = true
      (page.resources[:Pattern] ||= {})[name] ||= pattern_references.fetch(name)
      set_color(type, name, pattern: true)
    end

    def resume_graphic_settings(previous)
      previous ||= PDF::Core::GraphicState.new
      current = renderer.graphic_stack.current_state || PDF::Core::GraphicState.new
      differing = PrawnSwitch::GRAPHIC_SETTING_WRITERS.reject { |setting, _writer| paint(current, setting) == paint(previous, setting) }
      return if differing.empty?

      PrawnSwitch.taken = true
      state = graphic_state
      PrawnSwitch::RESUMED_STATE.each { |setting| state.public_send(:"#{setting}=", previous.public_send(setting).dup) }
      differing.each_value { |writer| send(writer) }
    end

    def paint(state, setting)
      case setting
      when :fill_paint then state.fill_pattern || state.fill_color
      when :stroke_paint then state.stroke_pattern || state.stroke_color
      else state.public_send(setting)
      end
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

  Prawn::Document::BoundingBox.prepend(Module.new do
    def move_past_bottom
      return super if @document.page_number == @document.page_count

      @document.send(:flow_onto_page, @document.page_number + 1)
    end
  end)
end

# ORACLE_SKIP_UNKNOWN_TEXT_RENDERING_MODE: like Gamba, a text rendering mode forgotten by forget_text_rendering_mode!
# is not written back, as a Tr without its operand, once a block ends. Prepended last, so that
# ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK does not record it either.
if ENV["ORACLE_SKIP_UNKNOWN_TEXT_RENDERING_MODE"]
  Prawn::Document.prepend(Module.new do
    def update_text_rendering_mode_state
      return super unless text_rendering_mode == :unknown

      PrawnSwitch.taken = true
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
  data = File.read(path, encoding: Encoding::UTF_8)
  OracleExample.new(name: "svg-#{File.basename(path, ".svg")}", options: {},
    block: proc { svg data, at: [bounds.left, bounds.top], width: bounds.width, enable_web_requests: false })
end

def examples_from(path)
  return [svg_example(path)] if path.end_with?(".svg")

  source = File.read(path, encoding: Encoding::UTF_8)
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
