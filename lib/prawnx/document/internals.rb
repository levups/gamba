# frozen_string_literal: true

module Prawn
  class Document
    # The document's objects, pages and graphic state stack: what Prawn splits between PDF::Core's renderer and its
    # document state.
    module Internals
      # A save not yet restored: the state in effect before it (nil on an empty stack, the default one), and the
      # ExtGState its block sets, {name:, reference:}, if any.
      OpenSave = Struct.new(:previous, :ext_gstate)
      DEFAULT_GRAPHIC_STATE = PDF::Core::GraphicState.new.freeze
      # The settings a new page writes, each with its writer, in the order Prawn writes them; a pattern replaces its
      # colour.
      GRAPHIC_SETTING_WRITERS = {fill_color: :set_fill_color, stroke_color: :set_stroke_color, line_width: :write_line_width,
                                 cap_style: :write_stroke_cap_style, join_style: :write_stroke_join_style, dash: :write_stroke_dash}.freeze
      # What a block ending on a later page writes back, in that order.
      RESUMED_SETTINGS = [*GRAPHIC_SETTING_WRITERS.keys, :blend_mode].freeze
      NORMAL_BLEND_MODE = "BMNormal"

      attr_reader :page, :pages, :pages_reference

      def ref(data)
        ref!(data).identifier
      end

      def ref!(data, stream = nil)
        reference = PDF::Core::Reference.new(@objects.size + 1, data, stream)
        @objects << reference
        reference
      end

      def deref(object)
        object.is_a?(PDF::Core::Reference) ? object.data : object
      end

      def add_content(string)
        open_graphics_state if page.stack.empty?
        page.content_stream << string << "\n"
      end

      def names
        @root.data[:Names] ||= ref!(Type: :Names)
      end

      def outlines_reference
        @root.data[:Outlines] ||= ref!(PDF::Core::OutlineRoot.new)
      end

      def names?
        @root.data.key?(:Names)
      end

      def before_render(&block)
        @before_render_callbacks << block
      end

      def on_page_create(&block)
        @on_page_create = block
      end

      def compression_enabled?
        @compress
      end

      def min_version(version)
        @version = version if version > @version
      end

      # Like Prawn, reading the state of a page whose stack was emptied opens a new one.
      def graphic_state
        open_graphics_state if page.stack.empty?
        page.stack.last
      end

      def save_graphics_state(graphic_state = nil)
        save_transformation_stack
        previous = graphic_state ? page.stack.last : self.graphic_state
        @unrestored_graphics_states << OpenSave.new(previous, nil)
        page.stack.push(PDF::Core::GraphicState.new(graphic_state || previous))
        add_content("q")
        return unless block_given?

        yield
        restore_graphics_state
      end

      # A page break leaves the blocks still open with states saved on an earlier page, which closed them when it
      # ended: like Prawn, their restore closes the state open on the new page (or one reopened for a block with an
      # ExtGState), and where none is open it has nothing left to close. Only a restore matching no save at all, on an
      # empty stack, raises.
      def restore_graphics_state
        restore_transformation_stack
        open_save = @unrestored_graphics_states.pop
        if page.stack.empty?
          raise Errors::EmptyGraphicStateStack, "\n You have reached the end of the graphic state stack" unless open_save
        else
          add_content("Q")
          page.stack.pop
        end
        resume_graphic_settings(open_save.previous) if open_save && !page.stack.last.equal?(open_save.previous)
      end

      def trailer
        @trailer
      end

      # What Prawn splits into a renderer and a state is this document itself: code written for Prawn calls both.
      def renderer
        self
      end

      def state
        self
      end

      def info
        @info.data
      end

      private

      def open_graphics_state
        page.stack.push(PDF::Core::GraphicState.new)
        page.content_stream << "q\n"
      end

      # The blocks still open saved their states on the page just closed. When one sets an ExtGState (opacity, blend
      # mode), the new page reopens them in order, the outermost in the page's own state, so each block's restore
      # closes its own state; otherwise the page stays as Prawn writes it.
      def reopen_ext_gstate_blocks
        return if @unrestored_graphics_states.none?(&:ext_gstate)

        outermost, *inner = @unrestored_graphics_states
        write_ext_gstate(outermost.ext_gstate) if outermost.ext_gstate
        inner.each do |open_save|
          page.stack.push(PDF::Core::GraphicState.new(graphic_state))
          add_content("q")
          write_ext_gstate(open_save.ext_gstate) if open_save.ext_gstate
        end
      end

      def ext_gstate_block(ext_gstate)
        save_graphics_state
        @unrestored_graphics_states.last.ext_gstate = ext_gstate
        write_ext_gstate(ext_gstate)
        yield
        restore_graphics_state
      end

      def write_ext_gstate(ext_gstate)
        page.ext_gstates[ext_gstate[:name]] = ext_gstate[:reference]
        add_content("/#{ext_gstate[:name]} gs")
        graphic_state.blend_mode = ext_gstate if ext_gstate[:reference].data.key?(:BM)
      end

      # The blend mode in effect on the page just closed, reset to Normal by the new one (ISO 32000-1 §8.4.1): once
      # the blocks still open are reopened, set it again if they leave another one.
      def resume_blend_mode(blend_mode)
        write_ext_gstate(blend_mode) unless same_blend_mode?(graphic_state.blend_mode, blend_mode)
      end

      def same_blend_mode?(blend_mode, other)
        (blend_mode&.fetch(:name) || NORMAL_BLEND_MODE) == (other&.fetch(:name) || NORMAL_BLEND_MODE)
      end

      # A block that saved its state on an earlier page ends on this one, where the state it returns to is the new
      # page's (the default one once that is closed), not the one in effect before the block: Prawn draws what follows
      # in black. Write back the settings that differ, as Prawn writes them on a new page.
      def resume_graphic_settings(previous)
        previous ||= DEFAULT_GRAPHIC_STATE
        current = page.stack.last || DEFAULT_GRAPHIC_STATE
        differing = RESUMED_SETTINGS.reject { |setting| same_setting?(setting, current, previous) }
        return if differing.empty?

        state = graphic_state
        GRAPHIC_SETTING_WRITERS.each_key { |setting| state.public_send(:"#{setting}=", previous.public_send(setting).dup) }
        differing.each { |setting| resume_setting(setting, previous) }
      end

      # A pattern paints in place of its colour, whatever that is.
      def same_setting?(setting, current, previous)
        case setting
        when :fill_color then same_paint?(current.fill_pattern, current.fill_color, previous.fill_pattern, previous.fill_color)
        when :stroke_color then same_paint?(current.stroke_pattern, current.stroke_color, previous.stroke_pattern, previous.stroke_color)
        when :blend_mode then same_blend_mode?(current.blend_mode, previous.blend_mode)
        else current.public_send(setting) == previous.public_send(setting)
        end
      end

      def same_paint?(pattern, color, previous_pattern, previous_color)
        previous_pattern ? pattern == previous_pattern : pattern.nil? && color == previous_color
      end

      def resume_setting(setting, previous)
        case setting
        when :fill_color then previous.fill_pattern ? write_pattern(:fill, previous.fill_pattern) : set_fill_color
        when :stroke_color then previous.stroke_pattern ? write_pattern(:stroke, previous.stroke_pattern) : set_stroke_color
        when :blend_mode then write_ext_gstate(previous.blend_mode || blend_mode_ext_gstate(:Normal))
        else send(GRAPHIC_SETTING_WRITERS.fetch(setting))
        end
      end

      def initialize_internals(options)
        @objects = []
        @info = ref!({Creator: "PrawnX", Producer: "PrawnX"}.merge(options[:info] || {}))
        @root = ref!(Type: :Catalog)
        @pages_reference = ref!(Type: :Pages, Count: 0, Kids: [])
        @root.data[:Pages] = @pages_reference
        @root.data[:ViewerPreferences] = {PrintScaling: :None} if options[:print_scaling] == :none
        @version = 1.3
        # One entry per save not yet restored, document-wide.
        @unrestored_graphics_states = []
        min_version(1.6) if options[:print_scaling] == :none
        @pages = []
        @page = nil
        @trailer = options.fetch(:trailer, {})
        @compress = options.fetch(:compress, false)
        @before_render_callbacks = []
        @on_page_create = nil
      end

      def insert_page(page, page_number)
        pages.insert(page_number, page)
        pages_reference.data[:Kids].insert(page_number, page.dictionary)
        pages_reference.data[:Count] += 1
      end

      def render_document
        pages.each_with_index do |page, index|
          go_to_page(index + 1)
          until page.stack.empty?
            page.content_stream << "Q\n"
            page.stack.pop
          end
          page.finalize
        end
        @before_render_callbacks.each { _1.call(self) }
        finalize_pdf_a if pdf_a?
        PDF::Core::Writer.call(objects: @objects, root: @root, info: @info, version: @version, trailer: @trailer, encryption: @encryption,
          identified: pdf_a?)
      end
    end
  end
end
