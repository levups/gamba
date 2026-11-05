# frozen_string_literal: true

module Prawn
  class Document
    # The document's objects, pages and graphic state stack: what Prawn splits between PDF::Core's renderer and its
    # document state.
    module Internals
      # A save not yet restored: the state in effect before it (nil on an empty stack, the default one), the
      # ExtGState its block sets, {name:, reference:}, if any, and whether it was restored since.
      OpenSave = Struct.new(:previous, :ext_gstate, :restored)
      DEFAULT_GRAPHIC_STATE = PDF::Core::GraphicState.new.freeze
      # The settings a block ending on a later page writes back, each with its writer, in the order Prawn writes them
      # on a new page, then the blend mode.
      GRAPHIC_SETTING_WRITERS = {fill_paint: :write_fill_paint, stroke_paint: :write_stroke_paint, line_width: :write_line_width,
                                 cap_style: :write_stroke_cap_style, join_style: :write_stroke_join_style, dash: :write_stroke_dash,
                                 blend_mode: :write_blend_mode}.freeze
      # What these writers read from the state.
      RESUMED_STATE = %i[fill_color fill_pattern stroke_color stroke_pattern line_width cap_style join_style dash blend_mode].freeze

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
        open_save = OpenSave.new(previous, nil, false)
        @unrestored_graphics_states << open_save
        page.stack.push(PDF::Core::GraphicState.new(graphic_state || previous))
        page.stack.last.save = open_save
        # A state given, as a dynamic repeater gives the one it was created in, still inherits the page's text state.
        page.stack.last.copy_text_state(previous) if graphic_state
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
        open_save&.restored = true
        if page.stack.empty?
          raise Errors::EmptyGraphicStateStack, "\n You have reached the end of the graphic state stack" unless open_save
        else
          add_content("Q")
          page.stack.pop
        end
        return unless open_save && !page.stack.last.equal?(open_save.previous)

        resume_graphic_settings(open_save.previous)
        resume_text_state
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

      # The states left open on a page by blocks that ended on another one: content drawn there again is drawn outside
      # them, as it would have been had the blocks ended there.
      def close_restored_graphics_states
        while page.stack.last&.save&.restored
          page.content_stream << "Q\n"
          page.stack.pop
        end
      end

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
        graphic_state.save = outermost
        write_ext_gstate(outermost.ext_gstate) if outermost.ext_gstate
        inner.each do |open_save|
          page.stack.push(PDF::Core::GraphicState.new(graphic_state))
          page.stack.last.save = open_save
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
        graphic_state.blend_mode = (ext_gstate[:name] == "BMNormal") ? nil : ext_gstate if ext_gstate[:reference].data.key?(:BM)
      end

      def write_blend_mode
        write_ext_gstate(graphic_state.blend_mode || blend_mode_ext_gstate(:Normal))
      end

      # A block that saved its state on an earlier page ends on this one, where the state it returns to is the new
      # page's (the default one once that is closed), not the one in effect before the block: Prawn draws what follows
      # in black. Write back the settings that differ, as Prawn writes them on a new page.
      def resume_graphic_settings(previous)
        previous ||= DEFAULT_GRAPHIC_STATE
        current = page.stack.last || DEFAULT_GRAPHIC_STATE
        differing = GRAPHIC_SETTING_WRITERS.reject { |setting, _writer| current.public_send(setting) == previous.public_send(setting) }
        return if differing.empty?

        state = graphic_state
        RESUMED_STATE.each { |setting| state.public_send(:"#{setting}=", previous.public_send(setting).dup) }
        differing.each_value { |writer| send(writer) }
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
