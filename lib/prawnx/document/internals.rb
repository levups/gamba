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

      # Sets an ExtGState of the registries, {name:, reference:}, in the current state of the page.
      def write_ext_gstate(ext_gstate)
        page.ext_gstates[ext_gstate[:name]] = ext_gstate[:reference]
        add_content("/#{ext_gstate[:name]} gs")
      end

      # A block that saved its state on an earlier page ends on this one, where the state it returns to is the new
      # page's (the default one once that is closed), not the one in effect before the block: Prawn draws what follows
      # in black. Write back the settings that differ, as Prawn writes them on a new page.
      def resume_graphic_settings(previous)
        previous ||= DEFAULT_GRAPHIC_STATE
        current = page.stack.last || DEFAULT_GRAPHIC_STATE
        fill = current.fill_color != previous.fill_color
        stroke = current.stroke_color != previous.stroke_color
        width = current.line_width != previous.line_width
        cap = current.cap_style != previous.cap_style
        join = current.join_style != previous.join_style
        dash = current.dash != previous.dash
        return unless fill || stroke || width || cap || join || dash

        state = graphic_state
        state.fill_color = previous.fill_color.dup
        state.stroke_color = previous.stroke_color.dup
        state.line_width = previous.line_width
        state.cap_style = previous.cap_style
        state.join_style = previous.join_style
        state.dash = previous.dash.dup
        set_fill_color if fill
        set_stroke_color if stroke
        write_line_width if width
        write_stroke_cap_style if cap
        write_stroke_join_style if join
        write_stroke_dash if dash
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
