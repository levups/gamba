# frozen_string_literal: true

module Prawn
  class Document
    # The document's objects, pages and graphic state stack: what Prawn splits between PDF::Core's renderer and its
    # document state.
    module Internals
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
        page.stack.push(PDF::Core::GraphicState.new(graphic_state || self.graphic_state))
        add_content("q")
        return unless block_given?

        yield
        restore_graphics_state
      end

      def restore_graphics_state
        restore_transformation_stack
        raise Errors::EmptyGraphicStateStack, "\n You have reached the end of the graphic state stack" if page.stack.empty?

        add_content("Q")
        page.stack.pop
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

      def initialize_internals(options)
        @objects = []
        @info = ref!({Creator: "PrawnX", Producer: "PrawnX"}.merge(options[:info] || {}))
        @root = ref!(Type: :Catalog)
        @pages_reference = ref!(Type: :Pages, Count: 0, Kids: [])
        @root.data[:Pages] = @pages_reference
        @root.data[:ViewerPreferences] = {PrintScaling: :None} if options[:print_scaling] == :none
        @version = 1.3
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
