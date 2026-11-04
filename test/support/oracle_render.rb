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
  OpenSave = Struct.new(:previous, :ext_gstate)
  # The settings a new page writes, each with its writer, in the order Prawn writes them.
  GRAPHIC_SETTING_WRITERS = {fill_color: :set_fill_color, stroke_color: :set_stroke_color, line_width: :write_line_width,
                             cap_style: :write_stroke_cap_style, join_style: :write_stroke_join_style, dash: :write_stroke_dash}.freeze
  RESUMED_SETTINGS = [*GRAPHIC_SETTING_WRITERS.keys, :blend_mode].freeze

  class << self
    attr_accessor :taken
  end
end

# ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK: like PrawnX, a page break reopens the open transparent and blend_mode blocks,
# then sets the blend mode in effect again, a new page paints with the gradients in effect, and a block saved on an
# earlier page writes back, once it ends, the settings in effect before it. Where any of these happened,
# <name>.switched: only there may PrawnX differ from plain Prawn (prawn_switch in test/divergences.yml).
if ENV["ORACLE_KEEP_STATE_ACROSS_PAGE_BREAK"]
  # Each state records, by name, the pattern painting in place of each colour and the blend mode, as PrawnX's does.
  PDF::Core::GraphicState.prepend(Module.new do
    attr_accessor :fill_pattern, :stroke_pattern, :blend_mode

    def initialize_copy(other)
      super
      @fill_pattern = other.fill_pattern
      @stroke_pattern = other.stroke_pattern
      @blend_mode = other.blend_mode
    end
  end)

  Prawn::Document.prepend(Module.new do
    # The block runs here, not in Prawn's renderer, whose restore would bypass this module's.
    def save_graphics_state(graphic_state = nil)
      open_saves << PrawnSwitch::OpenSave.new(renderer.graphic_stack.current_state, nil)
      super(graphic_state, &nil)
      return unless block_given?

      yield
      restore_graphics_state
    end

    def restore_graphics_state
      open_save = open_saves.pop
      super
      resume_graphic_settings(open_save.previous) if open_save && !renderer.graphic_stack.current_state.equal?(open_save.previous)
    end

    def transparent(opacity, stroke_opacity = opacity)
      super do
        open_saves.last.ext_gstate = -> { opacity_dictionary_name(opacity.clamp(0.0, 1.0), stroke_opacity.clamp(0.0, 1.0)) }
        yield
      end
    end

    def blend_mode(blend_mode = :Normal)
      name = "BM#{Array(blend_mode).join}"
      return super.tap { renderer.graphic_stack.current_state.blend_mode = name } unless block_given?

      super do
        renderer.graphic_stack.current_state.blend_mode = name
        open_saves.last.ext_gstate = -> { blend_mode_dictionary_name(blend_mode) }
        yield
      end
    end

    def set_color(type, color, options = {})
      super
      renderer.graphic_stack.current_state.public_send(:"#{type}_pattern=", (color if options[:pattern]))
    end

    def set_gradient(type, *, **)
      super
      renderer.graphic_stack.current_state.public_send(:"#{type}_pattern=", "SP#{gradient_registry_key(parse_gradient_arguments(*, **))}")
    end

    # Only start_new_page calls it, once the new page's state is a copy of the last page's: Prawn's, but a gradient
    # stays the fill or stroke, and the blend mode waits for the blocks to reopen.
    def use_graphic_settings(override_settings = false)
      state = renderer.graphic_stack.current_state
      @last_blend_mode = state.blend_mode
      state.blend_mode = nil
      if state.fill_pattern then write_pattern(:fill, state.fill_pattern)
      elsif current_fill_color != "000000" || override_settings then set_fill_color
      end
      if state.stroke_pattern then write_pattern(:stroke, state.stroke_pattern)
      elsif current_stroke_color != "000000" || override_settings then set_stroke_color
      end
      write_line_width if line_width != 1 || override_settings
      write_stroke_cap_style if cap_style != :butt || override_settings
      write_stroke_join_style if join_style != :miter || override_settings
      write_stroke_dash if dashed? || override_settings
    end

    def start_new_page(options = {})
      super
      return if options[:orphan]

      reopen_ext_gstate_blocks
      resume_blend_mode(@last_blend_mode)
    end

    private

    def open_saves
      @open_saves ||= []
    end

    def reopen_ext_gstate_blocks
      return if open_saves.none?(&:ext_gstate)

      PrawnSwitch.taken = true
      outermost, *inner = open_saves
      write_ext_gstate(outermost.ext_gstate.call) if outermost.ext_gstate
      inner.each do |open_save|
        renderer.graphic_stack.save_graphic_state
        renderer.add_content("q")
        write_ext_gstate(open_save.ext_gstate.call) if open_save.ext_gstate
      end
    end

    def write_ext_gstate(name)
      renderer.add_content("/#{name} gs")
      renderer.graphic_stack.current_state.blend_mode = name if name.start_with?("BM")
    end

    def write_pattern(type, name)
      PrawnSwitch.taken = true
      (page.resources[:Pattern] ||= {})[name] ||= gradient_registry[name.delete_prefix("SP")]
      set_color(type, name, pattern: true)
    end

    def resume_blend_mode(blend_mode)
      return if (renderer.graphic_stack.current_state&.blend_mode || "BMNormal") == (blend_mode || "BMNormal")

      PrawnSwitch.taken = true
      write_blend_mode(blend_mode)
    end

    # The blend mode named, nil for Normal, set as it was first: registered already, but on this page.
    def write_blend_mode(name)
      key = name&.delete_prefix("BM") || "Normal"
      write_ext_gstate(blend_mode_dictionary_name((key == "Normal") ? :Normal : key))
    end

    def resume_graphic_settings(previous)
      previous ||= PDF::Core::GraphicState.new
      current = renderer.graphic_stack.current_state || PDF::Core::GraphicState.new
      differing = PrawnSwitch::RESUMED_SETTINGS.reject { |setting| same_setting?(setting, current, previous) }
      return if differing.empty?

      PrawnSwitch.taken = true
      state = graphic_state
      PrawnSwitch::GRAPHIC_SETTING_WRITERS.each_key { |setting| state.public_send(:"#{setting}=", previous.public_send(setting).dup) }
      differing.each do |setting|
        case setting
        when :fill_color then previous.fill_pattern ? write_pattern(:fill, previous.fill_pattern) : set_fill_color
        when :stroke_color then previous.stroke_pattern ? write_pattern(:stroke, previous.stroke_pattern) : set_stroke_color
        when :blend_mode then write_blend_mode(previous.blend_mode)
        else send(PrawnSwitch::GRAPHIC_SETTING_WRITERS.fetch(setting))
        end
      end
    end

    def same_setting?(setting, current, previous)
      case setting
      when :fill_color, :stroke_color
        pattern = :"#{setting.to_s.delete_suffix("_color")}_pattern"
        if previous.public_send(pattern)
          current.public_send(pattern) == previous.public_send(pattern)
        else
          current.public_send(pattern).nil? && current.public_send(setting) == previous.public_send(setting)
        end
      when :blend_mode then (current.blend_mode || "BMNormal") == (previous.blend_mode || "BMNormal")
      else current.public_send(setting) == previous.public_send(setting)
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
