# frozen_string_literal: true

module PDF::Core
  # One page: its geometry, the content stream being written, its resources and the stack of graphic states.
  class Page
    DEFAULT_MARGINS = {left: 36, right: 36, top: 36, bottom: 36}.freeze
    NO_INDENTS = {left: 0, bottom: 0, right: 0, top: 0}.freeze

    attr_accessor :margins, :crops, :bleeds, :trims, :art_indents, :stack
    attr_reader :document, :content

    def initialize(document, options = {})
      @document = document
      @margins = options[:margins] || DEFAULT_MARGINS.dup
      @crops = options[:crops] || NO_INDENTS
      @bleeds = options[:bleeds] || NO_INDENTS
      @trims = options[:trims] || NO_INDENTS
      @art_indents = options[:art_indents] || NO_INDENTS
      @stack = [GraphicState.new(options[:graphic_state])]
      @size = options[:size] || "LETTER"
      @layout = options[:layout] || :portrait
      @content = document.ref!({}, (+"q\n").b)
      @dictionary = document.ref!(Type: :Page, Parent: document.pages_reference, MediaBox: dimensions, Contents: @content)
      @stamp_stream = nil
      @stamp_dictionary = nil
    end

    def graphic_state
      stack.last
    end

    def size
      @size || dimensions[2, 2]
    end

    def layout
      @layout || ((dimensions[3] > dimensions[2]) ? :portrait : :landscape)
    end

    def content_stream
      @stamp_stream || content.stream
    end

    def dictionary
      @stamp_dictionary || @dictionary
    end

    # Writes what the block draws into a form XObject instead of the page, starting from a copy of the current
    # graphic settings.
    def stamp_stream(reference)
      @stamp_dictionary = reference
      @stamp_stream = reference.stream
      depth = stack.size
      document.save_graphics_state
      document.__send__(:freeze_stamp_graphics)
      yield if block_given?
      document.restore_graphics_state until stack.size == depth
      @stamp_stream = nil
      @stamp_dictionary = nil
    end

    def in_stamp_stream?
      !@stamp_stream.nil?
    end

    def resources
      dictionary.data[:Resources] ||= {}
    end

    def fonts
      resources[:Font] ||= {}
    end

    def xobjects
      resources[:XObject] ||= {}
    end

    def ext_gstates
      resources[:ExtGState] ||= {}
    end

    def dimensions
      sides = PageGeometry::SIZES[@size] || @size
      sides =
        case @layout
        when :portrait then sides
        when :landscape then sides.reverse
        else raise Prawn::Errors::InvalidPageLayout, "Layout must be either :portrait or :landscape"
        end
      [0, 0, *sides]
    end

    def crop_box
      boxed(crops)
    end

    def bleed_box
      boxed(bleeds)
    end

    def trim_box
      boxed(trims)
    end

    def art_box
      boxed(art_indents)
    end

    # Resources are required even when empty; every box defaults to the media box, so only those that differ are
    # written.
    def finalize
      resources
      {CropBox: crop_box, BleedBox: bleed_box, TrimBox: trim_box, ArtBox: art_box}.each do |name, box|
        dictionary.data[name] = box unless box == dimensions
      end
    end

    private

    def boxed(indents)
      left, bottom, right, top = dimensions
      [left + indents[:left], bottom + indents[:bottom], right - indents[:right], top - indents[:top]]
    end
  end
end
