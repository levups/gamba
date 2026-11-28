# frozen_string_literal: true

module Gamba
  # Each page keeps its resources and content streams as they were encoded; only the page dictionaries and the
  # document structure are written anew. Outlines are carried over, and links land on the copies of their pages,
  # named destinations included; forms and tagged structure of the sources are not.
  class Combine
    include PageBoxes

    BOXES = %i[MediaBox CropBox BleedBox TrimBox ArtBox].freeze
    SOURCE_KEYS = %i[pdf pages rotate outline].freeze
    # Outline items and name tree nodes followed, at most: real files hold far fewer, crafted ones loop.
    MAX_OUTLINE_ITEMS = 100_000
    MAX_NAME_TREE_DEPTH = 64
    GO_TO = PDF::Core::Name.new(value: "GoTo")
    # A quarter turn counterclockwise, the way combine_pdf turns a page to the requested orientation.
    QUARTER_TURN = ROTATIONS.fetch(270)

    # page_size: a name from PDF::Core::PageGeometry::SIZES or [width, height] in points; each page is scaled to fit
    # it, keeping its proportions, from the lower left corner. orientation: :portrait or :landscape; a page the other
    # way round turns a quarter. A page /Rotate is applied to its content first. With neither, pages are copied
    # untouched.
    def initialize(page_size: nil, orientation: nil)
      @orientation = orientation&.to_sym
      raise ArgumentError, "orientation must be :portrait or :landscape" unless [nil, :portrait, :landscape].include?(@orientation)

      @page_size = page_size_in_points(page_size)
    end

    # Each source is a PDF (bytes, or an IO), or a Hash: {pdf:, pages: 1..3 or [2, 5] (from 1, in the order given),
    # rotate: a quarter turn clockwise or more (90, 180, 270), outline: a title its bookmarks go under}.
    def call(sources)
      @objects = []
      @kids = []
      @identifiers = {}
      @shared = {}
      @outline_items = []
      @pages_reference = reference({Type: :Pages})
      root = reference({Type: :Catalog, Pages: @pages_reference})
      info = reference({Producer: "Gamba"})
      version = sources.map { copy_source(**source_options(_1)) }.max || 1.3
      @pages_reference.data.merge!(Kids: @kids, Count: @kids.size)
      root.data[:Outlines] = outline_root(@outline_items) unless @outline_items.empty?
      finish_catalog(root)
      PDF::Core::Writer.call(objects: @objects, root:, info:, version:)
    end

    private

    # What a subclass adds to the catalog once the pages are copied.
    def finish_catalog(_root)
    end

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

    def source_options(source)
      return {pdf: source} unless source.is_a?(Hash)

      unknown = source.keys - SOURCE_KEYS
      raise ArgumentError, "Unknown source options #{unknown.map(&:inspect).join(", ")}: #{SOURCE_KEYS.join(", ")}" unless unknown.empty?
      raise ArgumentError, "a source Hash takes its PDF as pdf:" unless source.key?(:pdf)

      rotate = source.fetch(:rotate, 0)
      raise ArgumentError, "rotate is #{rotate.inspect}: give a multiple of 90" unless rotate.is_a?(Integer) && (rotate % 90).zero?
      if source.key?(:outline) && !(source[:outline].is_a?(String) && !source[:outline].empty?)
        raise ArgumentError, "outline is #{source[:outline].inspect}: give a title"
      end

      source
    end

    def copy_source(pdf:, pages: nil, rotate: 0, outline: nil)
      reader = PDF::Core::Reader.new(source_bytes(pdf))
      all_pages = reader.pages
      numbers = page_numbers(pages, all_pages.size)
      selected = numbers.map { all_pages[_1 - 1] }
      copies = copy_pages(reader, selected, all_pages, rotate % 360)
      copy_outline(reader, outline, copies.first)
      reader.version
    end

    def page_numbers(pages, count)
      return (1..count).to_a if pages.nil?

      numbers = case pages
      when Integer then [pages]
      when Range then pages.to_a
      when Array then pages
      else raise ArgumentError, "pages is #{pages.inspect}: give a Range, an Array or an Integer, from 1"
      end
      outside = numbers.reject { _1.is_a?(Integer) && _1.between?(1, count) }
      raise ArgumentError, "pages #{outside.inspect}: this PDF has pages 1 to #{count}" unless outside.empty?

      numbers
    end

    def reference(data)
      PDF::Core::Reference.new(@objects.size + 1, data).tap { @objects << _1 }
    end

    # Page references first, so a link from one page to another lands on the copy instead of dragging the old tree;
    # one to a page left out leads nowhere. A page taken twice is linked to as its first copy.
    def copy_pages(reader, selected, all_pages, rotate)
      @reader = reader
      @copier = Copier.new(reader, shared: @shared, identifiers: @identifiers) { reference(_1) }
      all_pages.each { |source_reference, _page| @copier.leave_out(source_reference.number) if source_reference.is_a?(PDF::Core::Reader::Ref) }
      placed = {}
      pages = selected.map do |source_reference, page|
        copy = reference(nil)
        if source_reference.is_a?(PDF::Core::Reader::Ref) && !placed[source_reference.number]
          placed[source_reference.number] = true
          @copier.place(source_reference.number, copy)
        end
        page = page.merge(Rotate: (rotation(page) + rotate) % 360) unless rotate.zero?
        [copy, page]
      end
      annotations_to_move = []
      pages.each do |copy, page|
        matrix, *sizes = transformation(page)
        copy.data = @copier.copy(matrix ? page.except(:Parent, :B, *BOXES, :Rotate, :Contents) : page.except(:Parent, :B))
        copy.data[:Parent] = @pages_reference
        # A page names its resources even when it has none (ISO 32000-1 §7.7.3.3): qpdf 12.4 repairs a page without.
        copy.data[:Resources] ||= {}
        if matrix
          reshape(copy.data, page, matrix, *sizes)
          annotations_to_move << [copy.data[:Annots], matrix] if copy.data[:Annots]
        end
        @kids << copy
      end
      @copier.finish
      resolve_named_link_destinations(pages.map(&:first))
      @copier.finish
      moved = {}.compare_by_identity
      annotations_to_move.each { |annotations, matrix| move_annotations(annotations, matrix, moved) }
      pages.map(&:first)
    end

    # Links naming a destination of their file point to it explicitly: names would clash between files.
    def resolve_named_link_destinations(copies)
      copies.each do |copy|
        annotations = copy.data[:Annots]
        annotations = annotations.data if annotations.is_a?(PDF::Core::Reference)
        Array(annotations).each do |annotation|
          dictionary = annotation.is_a?(PDF::Core::Reference) ? annotation.data : annotation
          next unless dictionary.is_a?(Hash)

          if named?(dictionary[:Dest])
            dictionary[:Dest] = copied_destination(dictionary[:Dest])
          elsif (action = dictionary[:A]).is_a?(Hash) && action[:S] == GO_TO && named?(action[:D])
            dictionary[:A] = action.merge(D: copied_destination(action[:D]))
          end
        end
      end
    end

    def named?(destination)
      destination.is_a?(PDF::Core::ByteString) || destination.is_a?(String) || destination.is_a?(PDF::Core::Name)
    end

    # A destination of the source, explicit, as an array whose page is the copy: nil when it names nothing or
    # points to a page left out.
    def copied_destination(destination)
      destination = named_destination(destination) if named?(destination)
      destination = @reader.resolve(destination)
      destination = @reader.resolve(destination[:D]) if destination.is_a?(Hash)
      return nil unless destination.is_a?(Array) && !destination.empty?

      copied = @copier.copy(destination)
      copied.first.nil? ? nil : copied
    end

    def named_destination(name)
      catalog = @reader.catalog
      if name.is_a?(PDF::Core::Name)
        dests = @reader.resolve(catalog[:Dests])
        return dests.is_a?(Hash) ? dests[name.value.to_sym] : nil
      end

      names = @reader.resolve(catalog[:Names])
      names.is_a?(Hash) ? name_tree_value(@reader.resolve(names[:Dests]), name.b, 0, {}) : nil
    end

    def name_tree_value(node, key, depth, visited)
      return nil unless node.is_a?(Hash) && depth < MAX_NAME_TREE_DEPTH

      pairs = @reader.resolve(node[:Names])
      if pairs.is_a?(Array)
        pairs.each_slice(2) { |name, value| return value if @reader.resolve(name).to_s.b == key }
      end
      Array(@reader.resolve(node[:Kids])).each do |kid|
        next if kid.is_a?(PDF::Core::Reader::Ref) && (visited[kid.number] || !(visited[kid.number] = true))

        value = name_tree_value(@reader.resolve(kid), key, depth + 1, visited)
        return value if value
      end
      nil
    end

    # The source's bookmarks, with their destinations on the copies, after those of the sources before it; under one
    # item titled outline, leading to the source's first page, when it is given.
    def copy_outline(reader, title, first_page)
      outlines = reader.resolve(reader.catalog[:Outlines])
      items = outlines.is_a?(Hash) ? outline_items(reader.resolve(outlines[:First]), 0) : []
      @copier.finish
      if title
        @outline_items << {Title: PDF::Core::ByteString.new(title.encode(Encoding::UTF_16BE).prepend("\uFEFF".encode(Encoding::UTF_16BE)).b), Dest: first_page && [first_page, :Fit], children: items}
      else
        @outline_items.concat(items)
      end
    end

    # Each item of a level, siblings through Next, children through First, as {Title:, Dest: or A:, children:}.
    def outline_items(item, depth)
      items = []
      @outline_count ||= 0
      visited = {}
      while item.is_a?(Hash) && depth < MAX_NAME_TREE_DEPTH && (@outline_count += 1) <= MAX_OUTLINE_ITEMS
        break if visited[item.object_id]

        visited[item.object_id] = true
        title = @reader.resolve(item[:Title])
        entry = {Title: title.is_a?(String) ? title : PDF::Core::ByteString.new(""), children: outline_items(@reader.resolve(item[:First]), depth + 1)}
        action = @reader.resolve(item[:A])
        if item[:Dest]
          entry[:Dest] = copied_destination(item[:Dest])
        elsif action.is_a?(Hash) && action[:S] == GO_TO
          entry[:Dest] = copied_destination(action[:D])
        elsif action
          entry[:A] = @copier.copy(item[:A])
        end
        # A bookmark to a page left out goes, unless it holds others.
        items << entry if entry[:Dest] || entry[:A] || !entry[:children].empty? || !(item[:Dest] || action)
        item = @reader.resolve(item[:Next])
      end
      items
    end

    # The outline tree of the items, each level linked both ways, closed below the top level.
    def outline_root(items)
      root = reference({Type: :Outlines})
      link_outline_items(root, items)
      root.data[:Count] = items.size
      root
    end

    def link_outline_items(parent, items)
      references = items.map do |item|
        reference(item.except(:children).compact.merge(Parent: parent))
      end
      references.each_cons(2) do |previous, following|
        previous.data[:Next] = following
        following.data[:Prev] = previous
      end
      items.zip(references) do |item, reference|
        next if item[:children].empty?

        link_outline_items(reference, item[:children])
        reference.data[:Count] = -item[:children].size
      end
      return if references.empty?

      parent.data[:First] = references.first
      parent.data[:Last] = references.last
    end

    # The matrix that draws the page's visible box at its new place, and the new page's size; nil when it stays put.
    def transformation(page)
      return nil unless @page_size || @orientation

      media = media_box(page)
      visible = visible_box(page)
      left, bottom, right, top = visible
      width = right - left
      height = top - bottom
      rotation = rotation(page)
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
      Array(value).filter_map { |content| @copier.copy(content) if content.is_a?(PDF::Core::Reader::Ref) }
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

    def plain_box(values)
      return nil unless values.is_a?(Array) && values.size == 4

      numbers = values.map { numeric(_1) }
      numbers.any?(&:nil?) ? nil : numbers
    end

    def apply(matrix, x, y)
      a, b, c, d, e, f = matrix
      [a * x + c * y + e, b * x + d * y + f]
    end
  end
end
