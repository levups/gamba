# frozen_string_literal: true

module Gamba
  # Each page keeps its resources and content streams as they were encoded; only the page dictionaries and the
  # document structure are written anew. Outlines, forms and tagged structure of the sources are not carried over.
  class Combine
    BOXES = %i[MediaBox CropBox BleedBox TrimBox ArtBox].freeze
    DEFAULT_MEDIA_BOX = [0.0, 0.0, 612.0, 792.0].freeze
    # A quarter turn counterclockwise, the way combine_pdf turns a page to the requested orientation.
    QUARTER_TURN = ->(width, height) { [0.0, 1.0, -1.0, 0.0, height, 0.0] }
    ROTATIONS = {
      90 => ->(width, height) { [0.0, -1.0, 1.0, 0.0, 0.0, width] },
      180 => ->(width, height) { [-1.0, 0.0, 0.0, -1.0, width, height] },
      270 => QUARTER_TURN
    }.freeze
    # References followed to tell whether two objects are the same: a chain deeper than this is copied unshared,
    # instead of overflowing the stack on a file that links its objects into a list as long as it likes.
    MAX_DESCRIBED_DEPTH = 32

    # page_size: a name from PDF::Core::PageGeometry::SIZES or [width, height] in points; each page is scaled to fit
    # it, keeping its proportions, from the lower left corner. orientation: :portrait or :landscape; a page the other
    # way round turns a quarter. A page /Rotate is applied to its content first. With neither, pages are copied
    # untouched.
    def initialize(page_size: nil, orientation: nil)
      @orientation = orientation&.to_sym
      raise ArgumentError, "orientation must be :portrait or :landscape" unless [nil, :portrait, :landscape].include?(@orientation)

      @page_size = page_size_in_points(page_size)
    end

    def call(sources)
      @objects = []
      @kids = []
      @identifiers = {}
      @shared = {}
      @pages_reference = reference({Type: :Pages})
      root = reference({Type: :Catalog, Pages: @pages_reference})
      info = reference({Producer: "Gamba"})
      version = sources.map { copy_pages(PDF::Core::Reader.new(source_bytes(_1))) }.max || 1.3
      @pages_reference.data.merge!(Kids: @kids, Count: @kids.size)
      PDF::Core::Writer.call(objects: @objects, root:, info:, version:)
    end

    private

    def page_size_in_points(page_size)
      return nil if page_size.nil?

      width, height = page_size.is_a?(Array) ? page_size : PDF::Core::PageGeometry::SIZES.fetch(page_size.to_s.upcase) { raise ArgumentError, "Unknown page size #{page_size.inspect}" }
      # With an orientation, the size follows it, as Prawn's page_layout does; without, it is used as given.
      width, height = [width, height].minmax if @orientation
      width, height = height, width if @orientation == :landscape
      [width.to_f, height.to_f]
    end

    def source_bytes(source)
      source.respond_to?(:read) ? source.read : source.to_s
    end

    def reference(data)
      PDF::Core::Reference.new(@objects.size + 1, data).tap { @objects << _1 }
    end

    # Page references first, so a link from one page to another lands on the copy instead of dragging the old tree.
    def copy_pages(reader)
      @reader = reader
      @copies = {}
      @pending = []
      @content_identifiers = {}
      @description_depth = 0
      pages = reader.pages.map do |source_reference, page|
        copy = reference(nil)
        if source_reference.is_a?(PDF::Core::Reader::Ref)
          @copies[source_reference.number] = copy
          @content_identifiers[source_reference.number] = nil
        end
        [copy, page]
      end
      annotations_to_move = []
      pages.each do |copy, page|
        matrix, *sizes = transformation(page)
        copy.data = copy_value(matrix ? page.except(:Parent, :B, *BOXES, :Rotate, :Contents) : page.except(:Parent, :B))
        copy.data[:Parent] = @pages_reference
        if matrix
          reshape(copy.data, page, matrix, *sizes)
          annotations_to_move << [copy.data[:Annots], matrix] if copy.data[:Annots]
        end
        @kids << copy
      end
      copy_pending
      moved = {}.compare_by_identity
      annotations_to_move.each { |annotations, matrix| move_annotations(annotations, matrix, moved) }
      reader.version
    end

    def copy_value(value)
      case value
      when PDF::Core::Reader::Ref
        @copies[value.number] ||= begin
          identifier = content_identifier(value.number)
          identifier ? (@shared[identifier] ||= pending_copy(value.number)) : pending_copy(value.number)
        end
      when Hash then value.transform_values { copy_value(_1) }
      when Array then value.map { copy_value(_1) }
      else value
      end
    end

    def pending_copy(number)
      reference(nil).tap { @pending << [number, _1] }
    end

    # Objects with the same content, references included, are written once: the fonts, images and glyph procedures a
    # carrier repeats on every label. Pages, and annotations (whose place is their own), are never shared.
    def content_identifier(number)
      return @content_identifiers[number] if @content_identifiers.key?(number)
      return nil if @description_depth >= MAX_DESCRIBED_DEPTH

      @content_identifiers[number] = nil # an object reached again while describing it stays unshared
      @description_depth += 1
      begin
        value = @reader.object(number)
        key = if value.is_a?(PDF::Core::Reader::Stream)
          description = describe(value.dictionary.except(:Length))
          [description, value.data] if description
        elsif !(value.is_a?(Hash) && value.key?(:Rect))
          describe(value)
        end
      ensure
        @description_depth -= 1
      end
      @content_identifiers[number] = key && (@identifiers[key] ||= @identifiers.size)
    end

    def describe(value, description = +"")
      case value
      when PDF::Core::Reader::Ref
        identifier = content_identifier(value.number)
        identifier && description << "R" << identifier.to_s << " "
      when Hash
        description << "<<"
        value.each { |key, entry| describe(entry, description << PDF::Core.escape_name(key.name) << " ") || (return nil) }
        description << ">>"
      when Array
        description << "["
        value.each { describe(_1, description) || (return nil) }
        description << "]"
      when PDF::Core::ByteString then description << "(" << value.bytesize.to_s << ":" << value << ")"
      when PDF::Core::Name then description << PDF::Core.escape_name(value.value) << " "
      when PDF::Core::Real then description << value.source << " "
      else description << value.inspect << " "
      end
    end

    def copy_pending
      until @pending.empty?
        number, copy = @pending.pop
        value = @reader.object(number)
        if value.is_a?(PDF::Core::Reader::Stream)
          dictionary = value.dictionary.except(:Length)
          # The writer packs streams without bytes as plain objects: keep one byte of data instead.
          dictionary = dictionary.except(:Filter, :DecodeParms) if value.data.empty?
          copy.data = copy_value(dictionary)
          copy.stream = value.data.empty? ? +" " : +value.data
        else
          copy.data = copy_value(value)
        end
      end
    end

    # The matrix that draws the page's visible box at its new place, and the new page's size; nil when it stays put.
    def transformation(page)
      return nil unless @page_size || @orientation

      media = box(page[:MediaBox]) || DEFAULT_MEDIA_BOX
      crop = box(page[:CropBox])
      visible = crop ? intersection(crop, media) : media
      left, bottom, right, top = visible
      width = right - left
      height = top - bottom
      rotation = number(page[:Rotate]).to_i % 360
      rotation = 0 unless (rotation % 90).zero?
      shown_width, shown_height = (rotation % 180).zero? ? [width, height] : [height, width]
      turn = @orientation && shown_width != shown_height && (shown_width > shown_height) != (@orientation == :landscape)
      final_width, final_height = turn ? [shown_height, shown_width] : [shown_width, shown_height]
      # Four decimals, as combine_pdf writes it: the same labels print the same.
      scale = @page_size ? [@page_size[0] / final_width, @page_size[1] / final_height].min.round(4) : 1.0
      page_width, page_height = @page_size || [final_width, final_height]
      return nil if rotation.zero? && !turn && visible == media && left.zero? && bottom.zero? && [width, height] == [page_width, page_height]

      matrix = [1.0, 0.0, 0.0, 1.0, -left, -bottom]
      matrix = multiply(matrix, ROTATIONS.fetch(rotation).call(width, height)) unless rotation.zero?
      matrix = multiply(matrix, QUARTER_TURN.call(shown_width, shown_height)) if turn
      matrix = multiply(matrix, [scale, 0.0, 0.0, scale, 0.0, 0.0])
      [matrix, page_width, page_height, final_width * scale, final_height * scale]
    end

    # The old content, clipped to the visible box, drawn through the matrix on a page of the new size.
    def reshape(dictionary, page, matrix, width, height, content_width, content_height)
      dictionary[:MediaBox] = [0, 0, width, height]
      prefix = reference({})
      prefix.stream = "q\n0 0 #{PDF::Core.real(content_width)} #{PDF::Core.real(content_height)} re W n\n#{PDF::Core.real_params(matrix)} cm\n"
      suffix = reference({})
      suffix.stream = +"\nQ\n"
      dictionary[:Contents] = [prefix, *contents(page[:Contents]), suffix]
    end

    def contents(value)
      resolved = @reader.resolve(value)
      value = resolved if resolved.is_a?(Array)
      Array(value).filter_map { |content| copy_value(content) if content.is_a?(PDF::Core::Reader::Ref) }
    end

    # Annotation rectangles follow the content they sit on.
    # An annotation listed by two pages, or an /Annots array two pages share, moves once.
    def move_annotations(annotations, matrix, moved)
      annotations = annotations.data if annotations.is_a?(PDF::Core::Reference)
      Array(annotations).each do |annotation|
        dictionary = annotation.is_a?(PDF::Core::Reference) ? annotation.data : annotation
        next if moved.key?(dictionary) || !dictionary.is_a?(Hash) || !(rectangle = plain_box(dictionary[:Rect]))

        moved[dictionary] = true
        corners = [apply(matrix, rectangle[0], rectangle[1]), apply(matrix, rectangle[2], rectangle[3])]
        xs, ys = corners.transpose
        dictionary[:Rect] = [xs.min, ys.min, xs.max, ys.max]
        turn_appearances(dictionary, matrix) unless matrix[1].zero? && matrix[2].zero? && matrix[0].positive?
      end
    end

    # Viewers fit an appearance's box into its Rect without turning it: a turned page turns its appearances
    # through their /Matrix. They are copies, so a form also drawn elsewhere keeps its own.
    def turn_appearances(annotation, matrix)
      appearances = annotation[:AP]
      appearances = appearances.data if appearances.is_a?(PDF::Core::Reference)
      return unless appearances.is_a?(Hash)

      linear = [*matrix.first(4), 0.0, 0.0]
      annotation[:AP] = appearances.transform_values do |appearance|
        states = (appearance.is_a?(PDF::Core::Reference) && !appearance.stream?) ? appearance.data : appearance
        next turned_form(appearance, linear) unless states.is_a?(Hash)

        states.transform_values { turned_form(_1, linear) }
      end
    end

    def turned_form(form, linear)
      return form unless form.is_a?(PDF::Core::Reference) && form.stream? && form.data.is_a?(Hash)

      own = plain_matrix(form.data[:Matrix])
      return form unless own

      reference(form.data.merge(Matrix: multiply(own, linear))).tap { |copy| copy.stream = form.stream }
    end

    def plain_matrix(values)
      return [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] if values.nil?
      return nil unless values.is_a?(Array) && values.size == 6

      numbers = values.map { numeric(_1) }
      numbers.all? ? numbers : nil
    end

    def box(value)
      values = @reader.resolve(value)
      return nil unless values.is_a?(Array) && values.size == 4

      numbers = values.map { number(_1) }
      return nil if numbers.any?(&:nil?) || numbers[0] == numbers[2] || numbers[1] == numbers[3]

      left, right = [numbers[0], numbers[2]].minmax
      bottom, top = [numbers[1], numbers[3]].minmax
      [left, bottom, right, top]
    end

    def plain_box(values)
      return nil unless values.is_a?(Array) && values.size == 4

      numbers = values.map { numeric(_1) }
      numbers.any?(&:nil?) ? nil : numbers
    end

    def number(value)
      numeric(@reader.resolve(value))
    end

    def numeric(value)
      (value.is_a?(PDF::Core::Real) || value.is_a?(Numeric)) ? value.to_f : nil
    end

    def intersection(crop, media)
      left, bottom = [crop[0], media[0]].max, [crop[1], media[1]].max
      right, top = [crop[2], media[2]].min, [crop[3], media[3]].min
      (right > left && top > bottom) ? [left, bottom, right, top] : media
    end

    def multiply(first, second)
      a, b, c, d, e, f = first
      a2, b2, c2, d2, e2, f2 = second
      [a * a2 + b * c2, a * b2 + b * d2, c * a2 + d * c2, c * b2 + d * d2, e * a2 + f * c2 + e2, e * b2 + f * d2 + f2]
    end

    def apply(matrix, x, y)
      a, b, c, d, e, f = matrix
      [a * x + c * y + e, b * x + d * y + f]
    end
  end
end
