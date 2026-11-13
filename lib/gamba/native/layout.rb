# frozen_string_literal: true

module Gamba
  # Boxes described first, measured, then placed: a stack puts its children one under the other and breaks pages
  # between them, a row puts them side by side on one page.
  module Layout
    FIT_TOLERANCE_POINTS = Prawn::FLOAT_PRECISION
    MEASURING_HEIGHT_POINTS = 100_000_000

    # The top of the next box on the current page, in absolute coordinates.
    class Cursor
      attr_accessor :y

      def initialize(prawn)
        @prawn = prawn
        @y = prawn.y
        @page_top = prawn.bounds.absolute_top
      end

      def remaining
        bounds = @prawn.bounds
        y - (bounds.stretchy? ? @prawn.margin_box.absolute_bottom : bounds.absolute_bottom)
      end

      def fits?(height)
        height <= remaining + FIT_TOLERANCE_POINTS
      end

      def at_page_top?
        y == @page_top
      end

      # What a box has from the top of a page: more cannot be kept together.
      def page_height
        bounds = @prawn.bounds
        @page_top - (bounds.stretchy? ? @prawn.margin_box.absolute_bottom : bounds.absolute_bottom)
      end

      def next_page
        @prawn.bounds.move_past_bottom
        @page_top = @y = @prawn.y
      end

      # Flows a decorated stack's children within its bounds, which keep its padding clear on every page.
      def within(bounds)
        @prawn.bounds = bounds
        @page_top = bounds.absolute_top
        yield
      ensure
        @prawn.bounds = bounds.outer
        @page_top = @prawn.bounds.absolute_top
      end
    end

    # The bounds of a stack with a background or a border while it flows across pages: its padding kept clear at
    # the top and the bottom of each page, its decoration drawn on each page beneath what that page holds of it,
    # as CSS's box-decoration-break: clone does. Text and tables break pages through these bounds, so each break
    # closes the stack's part on one page and opens it on the next.
    class DecoratedBounds < Prawn::Document::BoundingBox
      def initialize(prawn, stack, left, width, padding_top, padding_bottom)
        parent = prawn.bounds
        super(prawn, parent, [parent.absolute_left, parent.absolute_top], width: parent.width, height: 0)
        # The margin box is made anew on each page: bounds within it follow the current one.
        @within_margins = parent.equal?(prawn.margin_box)
        @stack = stack
        @left = left
        @box_width = width
        @padding_top = padding_top
        @padding_bottom = padding_bottom
      end

      def outer
        @within_margins ? @document.margin_box : @parent
      end

      def absolute_left
        outer.absolute_left + total_left_padding
      end

      def width
        outer.width - total_left_padding - total_right_padding
      end

      def absolute_top
        outer.absolute_top - @padding_top
      end

      def absolute_bottom
        outer_bottom + @padding_bottom
      end

      def height
        absolute_top - absolute_bottom
      end

      def stretchy?
        false
      end

      # The stack's part on this page reaches down to the bottom of what holds it, and its next part starts at the
      # top of the next page.
      def move_past_bottom
        end_part(outer_bottom, skip_empty: true)
        outer.move_past_bottom
        start_part(outer.absolute_top)
        @document.y = absolute_top
      end

      # The stack's part on this page starts at top: what is drawn from here is drawn over its decoration.
      def start_part(top)
        @top = top
        @offset = @document.page.content_stream.bytesize
        @graphic_state = @document.graphic_state.dup
      end

      def end_part(bottom, skip_empty: false)
        return if skip_empty && @document.page.content_stream.bytesize == @offset

        @stack.decorate_beneath(@document, @offset, @graphic_state, @left, @top, @box_width, @top - bottom)
      end

      private

      def outer_bottom
        outer.stretchy? ? @document.margin_box.absolute_bottom : outer.absolute_bottom
      end
    end

    class Node
      OPTIONS = %i[width grow keep_with_next].freeze

      attr_reader :width, :grow, :keep_with_next

      def initialize(width: nil, grow: nil, keep_with_next: false)
        raise ArgumentError, "width and grow exclude each other: a box is as wide as told, or shares what is left" if width && grow

        @width = width
        @grow = grow
        @keep_with_next = keep_with_next
      end

      # A box is measured when it is placed and again by the boxes around it: once per width is enough.
      def height(prawn, width)
        (@height_by_width ||= {})[width] ||= measure(prawn, width)
      end

      # The least of this box that can start a page: all of it, unless it can be split.
      def first_height(prawn, width)
        height(prawn, width)
      end

      # A box that cannot be split goes to the next page when the rest of this one is too short for it.
      def flow(prawn, cursor, left, width)
        height = height(prawn, width)
        cursor.next_page unless cursor.fits?(height) || cursor.at_page_top?
        unless cursor.fits?(height)
          raise Prawn::Errors::CannotFit, "#{description} is #{height.round(1)} pt high, the page has #{cursor.remaining.round(1)} pt: it cannot be split"
        end

        paint(prawn, left, cursor.y, width)
        cursor.y -= height
      end

      private

      def relative(prawn, left, top)
        [left - prawn.bounds.absolute_left, top - prawn.bounds.absolute_bottom]
      end
    end

    # A paragraph: its lines fill the page and the rest goes on to the next ones, never leaving fewer than
    # `orphans` lines at the bottom of a page nor fewer than `widows` at the top of the next.
    class Text < Node
      DEFAULT_WIDOWS = 2
      DEFAULT_ORPHANS = 2

      def initialize(string, font:, font_options:, color:, text_options:, widows: DEFAULT_WIDOWS, orphans: DEFAULT_ORPHANS, **)
        super(**)
        @fragments = [color ? {text: string, color:} : {text: string}]
        @font = font
        @font_options = font_options
        @text_options = text_options
        @widows = lines_option(:widows, widows)
        @orphans = lines_option(:orphans, orphans)
      end

      # The lines wrapped to measure the text are drawn as they are, when Prawn's box can draw them again.
      def paint(prawn, left, top, width)
        at = relative(prawn, left, top)
        with_font(prawn) do
          if @measured_width == width && @measured_box.layout_reusable?
            @measured_box.render_laid_out(at)
          else
            box(prawn, @fragments, at, width, MEASURING_HEIGHT_POINTS).render
          end
        end
      end

      def flow(prawn, cursor, left, width)
        with_font(prawn) do
          fragments = @fragments
          # How high the rest of the paragraph is at most, once a page took its first lines.
          rest_height = nil
          loop do
            at = relative(prawn, left, cursor.y)
            # The rest fits whole: no rule can apply, and nothing needs to be wrapped twice.
            if rest_height && cursor.fits?(rest_height)
              cursor.y -= advance(box(prawn, fragments, at, width, MEASURING_HEIGHT_POINTS).tap(&:render))
              break
            end

            # Measured already, by a box kept with this one: its lines serve again.
            probe = (fragments.equal?(@fragments) && @measured_width == width) ? @measured_box : laid_out(prawn, fragments, width)
            height = height_for_this_page(probe, cursor)
            if height.zero?
              cursor.next_page
              next
            end

            # Most paragraphs fit whole: the lines wrapped to place them are drawn as they are.
            if height == MEASURING_HEIGHT_POINTS && probe.layout_reusable?
              probe.render_laid_out(at)
              cursor.y -= advance(probe)
              break
            end

            box = box(prawn, fragments, at, width, height)
            unprinted = box.render
            cursor.y -= advance(box)
            break if unprinted.empty?

            # A first line takes no more than the line spacing it had below the line before it.
            rest_height = probe.height - height
            fragments = unprinted
            cursor.next_page
          end
        end
      end

      # A page can start with this paragraph's first `orphans` lines, or with all of it when it is shorter.
      def first_height(prawn, width)
        height(prawn, width)
        bottoms = @measured_box.line_bottoms
        return height(prawn, width) if bottoms.size <= @orphans

        bottoms[@orphans - 1]
      end

      private

      def lines_option(name, lines)
        return lines if lines.is_a?(Integer) && lines >= 1

        raise ArgumentError, "#{name} is #{lines.inspect}: give a number of lines, 1 or more"
      end

      def measure(prawn, width)
        with_font(prawn) do
          @measured_width = width
          @measured_box = laid_out(prawn, @fragments, width)
          advance(@measured_box)
        end
      end

      # The fragments wrapped at this width, with no height to stop them, their lines kept.
      def laid_out(prawn, fragments, width)
        box = box(prawn, fragments, [0, 0], width, MEASURING_HEIGHT_POINTS)
        box.render(dry_run: true, keep_layout: true)
        box
      end

      # The height to give this page's box, 0 when the paragraph moves on to the next page: as many lines as fit,
      # fewer when the rest would leave widows, none when what fits would leave orphans. At the top of a page,
      # a paragraph takes what fits whatever its rules: no other page would do better.
      def height_for_this_page(probe, cursor)
        return MEASURING_HEIGHT_POINTS if cursor.fits?(probe.height)

        bottoms = probe.line_bottoms
        fitting = bottoms.count { |bottom| bottom <= cursor.remaining + FIT_TOLERANCE_POINTS }
        if fitting.zero?
          raise Prawn::Errors::CannotFit, "#{description} has a line higher than the page" if cursor.at_page_top?

          return 0
        end
        return MEASURING_HEIGHT_POINTS if fitting == bottoms.size
        return bottoms[fitting - 1] if cursor.at_page_top?

        kept = [fitting, bottoms.size - @widows].min
        (kept >= @orphans) ? bottoms[kept - 1] : 0
      end

      def description
        "the text #{@fragments.first[:text][0, 30].inspect}"
      end

      # Prawn's font answers the font, not what its block returns.
      def with_font(prawn)
        return yield unless @font

        returned = nil
        prawn.font(@font, @font_options) { returned = yield }
        returned
      end

      def box(prawn, fragments, at, width, height)
        Prawn::Text::Formatted::Box.new(fragments, {document: prawn, at:, width:, height:, **@text_options})
      end

      # What Prawn's text moves the cursor by: the lines, and the gap that separates the last one from what follows.
      def advance(box)
        box.height + box.line_gap + box.leading
      end
    end

    # An image as a box: at its own size unless told a width or a height, never wider than its box, never distorted.
    class Image < Node
      OPTIONS = (Node::OPTIONS + %i[height align]).freeze
      ALIGNMENTS = %i[left center right].freeze

      def initialize(source, height: nil, align: :left, **)
        raise ArgumentError, "align is #{align.inspect}: accepted alignments are #{ALIGNMENTS.map(&:inspect).join(", ")}" unless ALIGNMENTS.include?(align)

        super(**)
        @source = source
        @height = height
        @align = align
      end

      def paint(prawn, left, top, width)
        image_width, image_height = size(prawn, width)
        offset = {left: 0, center: (width - image_width) / 2.0, right: width - image_width}.fetch(@align)
        prawn.embed_image(*image(prawn), at: relative(prawn, left + offset, top), width: image_width, height: image_height)
      end

      private

      def measure(prawn, width)
        size(prawn, width).last
      end

      def description
        "an image"
      end

      def image(prawn)
        @image ||= prawn.build_image_object(@source)
      end

      def size(prawn, available_width)
        info = image(prawn).last
        ratio = info.width / info.height.to_f
        image_width = @height ? @height * ratio : (width || info.width)
        image_width = [image_width, available_width].min
        [image_width, image_width / ratio]
      end
    end

    # A page of another PDF as a box, sized and aligned as an image is.
    class PdfPage < Image
      def initialize(source, page: 1, **)
        super(source, **)
        @page = page
      end

      private

      def description
        "a PDF page"
      end

      def image(prawn)
        @image ||= prawn.build_pdf_page_object(@source, @page)
      end
    end

    # A QR code or a DataMatrix as a box: size wide, its quiet zone included, or as many points per module as
    # module_size says; never wider than its box.
    class MatrixCode < Node
      OPTIONS = (Node::OPTIONS + %i[size module_size quiet_zone color align]).freeze

      def initialize(symbol, size: nil, module_size: Prawn::Barcodes::DEFAULT_MODULE_SIZE, quiet_zone: true, color: "000000", align: :left, **)
        raise ArgumentError, "align is #{align.inspect}: accepted alignments are #{Image::ALIGNMENTS.map(&:inspect).join(", ")}" unless Image::ALIGNMENTS.include?(align)

        super(**)
        @symbol = symbol
        @size = size
        @module_size = module_size
        @quiet_zone = quiet_zone
        @color = color
        @align = align
      end

      def paint(prawn, left, top, width)
        size = side(width)
        offset = {left: 0, center: (width - size) / 2.0, right: width - size}.fetch(@align)
        prawn.draw_matrix_code(@symbol, at: relative(prawn, left + offset, top), size:, quiet_zone: @quiet_zone, color: @color)
      end

      private

      def measure(_prawn, width)
        side(width)
      end

      def side(available_width)
        modules = @symbol.size + (@quiet_zone ? 2 * @symbol.quiet_zone : 0)
        [@size || width || (modules * @module_size), available_width].min
      end

      def description
        @symbol.is_a?(Gamba::Barcodes::QRCode) ? "a QR code" : "a DataMatrix"
      end
    end

    # A linear barcode as a box: as wide as told, quiet zones included, or as many points per module as
    # module_size says; never wider than its box.
    class Barcode < Node
      OPTIONS = (Node::OPTIONS + %i[type module_size height text text_size color quiet_zone align]).freeze

      def initialize(data, type:, align: :left, **options)
        raise ArgumentError, "align is #{align.inspect}: accepted alignments are #{Image::ALIGNMENTS.map(&:inspect).join(", ")}" unless Image::ALIGNMENTS.include?(align)

        super(**options.slice(*Node::OPTIONS))
        @symbol = Gamba::Barcodes::Linear.new(data, type:)
        @options = options.except(*Node::OPTIONS)
        @align = align
      end

      def paint(prawn, left, top, width)
        options = drawn(width)
        offset = {left: 0, center: (width - options[:width]) / 2.0, right: width - options[:width]}.fetch(@align)
        prawn.draw_barcode(@symbol, at: relative(prawn, left + offset, top), **options)
      end

      private

      def measure(_prawn, width)
        Prawn::Barcodes.linear_dimensions(@symbol, drawn(width)).last
      end

      # The options to draw it with: its width at most the box's.
      def drawn(available_width)
        natural = Prawn::Barcodes.linear_dimensions(@symbol, {width: width}.compact.merge(@options))[4]
        @options.merge(width: [natural, available_width].min)
      end

      def description
        "a barcode"
      end
    end

    # What a document and its containers share: the calls that add a box.
    module Builder
      # Rows are hashes, or objects answering the columns' names. The block receives the Prawn::Table before it
      # is laid out, for what the options do not cover: spans, the style of one cell.
      def table(rows, **options, &styling)
        add(Table.new(rows, styling, @styles, **options))
      end

      def image(source, **options)
        Styles.check_options(options, Image::OPTIONS)
        add(Image.new(source, **options))
      end

      def barcode(data, **options)
        Styles.check_options(options, Barcode::OPTIONS)
        add(Barcode.new(data, **options))
      end

      def qr_code(text, level: :m, **options)
        Styles.check_options(options, MatrixCode::OPTIONS)
        add(MatrixCode.new(Gamba::Barcodes::QRCode.new(text, level:), **options))
      end

      def data_matrix(data, **options)
        Styles.check_options(options, MatrixCode::OPTIONS)
        add(MatrixCode.new(Gamba::Barcodes::DataMatrix.new(data), **options))
      end

      # A page of another PDF (a path, an IO or its bytes), from 1, as a box sized like an image.
      def pdf_page(source, page: 1, **options)
        Styles.check_options(options, Image::OPTIONS)
        add(PdfPage.new(source, page:, **options))
      end

      def stack(**options)
        container = Stack.new(@styles, **options)
        yield container
        add(container)
      end

      def row(**options)
        container = Row.new(@styles, **options)
        yield container
        add(container)
      end

      # Cells side by side, `columns` to a line, all as wide; a line is as high as its tallest cell.
      def grid(columns:, **options)
        container = Grid.new(@styles, columns:, **options)
        yield container
        add(container)
      end

      # Draws anything that answers call(builder): a document is made of small objects, each tested alone.
      def draw(component)
        component.call(self)
        self
      end
    end

    class Container < Node
      include Builder

      OPTIONS = (Node::OPTIONS + %i[gap padding background border_width border_color]).freeze
      DEFAULT_BORDER_COLOR = "000000"

      def initialize(styles, gap: 0, padding: 0, background: nil, border_width: nil, border_color: nil, **)
        super(**)
        @styles = styles
        @gap = gap
        @padding_top, @padding_right, @padding_bottom, @padding_left = edges(padding)
        @background = background
        @border_width = border_width || (0.5 if border_color)
        @border_color = border_color || DEFAULT_BORDER_COLOR
        @children = []
      end

      def text(string, style: nil, width: nil, grow: nil, **attributes)
        add(Text.new(string, width:, grow:, **@styles.text_arguments(style, attributes)))
      end

      # Draws the decoration under what the page's content stream holds from offset on, in the graphic state the
      # stream was in there.
      def decorate_beneath(prawn, offset, graphic_state, left, top, width, height)
        stream = prawn.page.content_stream
        start = stream.bytesize
        decorate(prawn, left, top, width, height, graphic_state)
        stream.insert(offset, stream.slice!(start..))
      end

      private

      def add(node)
        @children << node
        self
      end

      def decorated?
        @background || @border_width
      end

      def decorate(prawn, left, top, width, height, graphic_state = nil)
        return unless decorated?

        prawn.save_graphics_state(graphic_state) do
          corner = relative(prawn, left, top)
          if @background
            prawn.fill_color(@background)
            prawn.fill_rectangle(corner, width, height)
          end
          if @border_width
            prawn.line_width(@border_width)
            prawn.stroke_color(@border_color)
            prawn.stroke_rectangle(corner, width, height)
          end
        end
      end

      def inner_width(width)
        width - @padding_left - @padding_right
      end

      # CSS's order: one value for the four edges, [vertical, horizontal], or [top, right, bottom, left].
      def edges(padding)
        case padding
        in Numeric then [padding] * 4
        in [Numeric => vertical, Numeric => horizontal] then [vertical, horizontal, vertical, horizontal]
        in [Numeric, Numeric, Numeric, Numeric] then padding
        else raise ArgumentError, "padding is #{padding.inspect}: give one number, [vertical, horizontal] or [top, right, bottom, left]"
        end
      end
    end

    class Stack < Container
      OPTIONS = (Container::OPTIONS + %i[keep_together]).freeze

      def initialize(styles, **options)
        Styles.check_options(options, OPTIONS)
        @keep_together = options.delete(:keep_together)
        super
      end

      # In a line of a grid, the background and the border reach down to the bottom of the line.
      def paint(prawn, left, top, width, stretched_height = nil)
        decorate(prawn, left, top, width, stretched_height || height(prawn, width))
        child_top = top - @padding_top
        @children.each do |child|
          child_width = child_width(child, width)
          child.paint(prawn, left + @padding_left, child_top, child_width)
          child_top -= child.height(prawn, child_width) + @gap
        end
      end

      # A stack breaks pages between its children, and a text among them between its lines; one kept together
      # moves as one box. A background or a border is drawn on each page around what it holds of the stack.
      def flow(prawn, cursor, left, width)
        return super if @keep_together || (decorated? && cursor.fits?(height(prawn, width)))
        return flow_children(prawn, cursor, left, width) unless decorated?

        cursor.next_page unless cursor.at_page_top? || cursor.fits?(first_height(prawn, width) + @padding_bottom)
        bounds = DecoratedBounds.new(prawn, self, left, width, @padding_top, @padding_bottom)
        bounds.start_part(cursor.y)
        cursor.within(bounds) { flow_children(prawn, cursor, left, width) }
        bounds.end_part(cursor.y)
      end

      # A page can start with the top of this stack's first child, unless the stack is kept together.
      def first_height(prawn, width)
        return height(prawn, width) if @keep_together || @children.empty?

        first = @children.first
        @padding_top + first.first_height(prawn, child_width(first, width))
      end

      private

      def flow_children(prawn, cursor, left, width)
        cursor.y -= @padding_top
        @children.each_with_index do |child, index|
          cursor.y -= @gap unless index.zero? || cursor.at_page_top?
          keep_with_what_follows(prawn, cursor, width, index)
          child.flow(prawn, cursor, left + @padding_left, child_width(child, width))
        end
        cursor.y -= @padding_bottom
      end

      # Children kept with the next go to the next page together with the start of the one after them, when this
      # page is too short for all of it and a page is not.
      def keep_with_what_follows(prawn, cursor, width, index)
        return if cursor.at_page_top? || (index.positive? && @children[index - 1].keep_with_next)

        kept = @children[index..].take_while(&:keep_with_next)
        following = @children[index + kept.size]
        return if kept.empty? || following.nil?

        needed = kept.sum { |child| child.height(prawn, child_width(child, width)) + @gap } +
          following.first_height(prawn, child_width(following, width))
        cursor.next_page if !cursor.fits?(needed) && needed <= cursor.page_height + FIT_TOLERANCE_POINTS
      end

      def measure(prawn, width)
        @padding_top + @padding_bottom + (@gap * [@children.size - 1, 0].max) +
          @children.sum { |child| child.height(prawn, child_width(child, width)) }
      end

      def description
        "a stack kept together"
      end

      def child_width(child, width)
        raise ArgumentError, "grow shares the width of a row: it means nothing in a stack" if child.grow

        [child.width || inner_width(width), inner_width(width)].min
      end
    end

    # The boxes of a document kept with what follows them, waiting for it to be placed together.
    class Group < Stack
      def push(node)
        add(node)
      end
    end

    class Row < Container
      def initialize(styles, **options)
        Styles.check_options(options, OPTIONS)
        super
      end

      def paint(prawn, left, top, width, stretched_height = nil)
        decorate(prawn, left, top, width, stretched_height || height(prawn, width))
        child_left = left + @padding_left
        paint_children(prawn, child_left, top, width)
      end

      private

      def paint_children(prawn, child_left, top, width)
        @children.zip(child_widths(width)) do |child, child_width|
          child.paint(prawn, child_left, top - @padding_top, child_width)
          child_left += child_width + @gap
        end
      end

      def measure(prawn, width)
        widths = child_widths(width)
        tallest = 0
        @children.each_with_index do |child, index|
          height = child.height(prawn, widths[index])
          tallest = height if height > tallest
        end
        @padding_top + @padding_bottom + tallest
      end

      def description
        "a row"
      end

      # Children told their width take it; the others share what is left by their grow, 1 unless told.
      def child_widths(width)
        shared = inner_width(width) - (@gap * [@children.size - 1, 0].max) - @children.sum { |child| child.width || 0 }
        total_grow = @children.sum { |child| child.width ? 0 : child.grow || 1 }
        raise Prawn::Errors::CannotFit, "a row's children are #{-shared.round(1)} pt wider than the row" if shared.negative?

        @children.map { |child| child.width || (shared * (child.grow || 1) / total_grow.to_f) }
      end
    end

    # Cells in lines of `columns`: a stack of rows whose cells are all as wide, the last line's included. Pages
    # break between lines, never inside one. gap is one number, or [between lines, between columns].
    class Grid < Stack
      OPTIONS = (Stack::OPTIONS + %i[columns]).freeze

      def initialize(styles, columns:, gap: 0, **options)
        unless columns.is_a?(Integer) && columns.positive?
          raise ArgumentError, "columns is #{columns.inspect}: give the number of cells on a line, 1 or more"
        end

        Styles.check_options(options, OPTIONS)
        line_gap, @column_gap = grid_gaps(gap)
        @columns = columns
        super(styles, gap: line_gap, **options)
      end

      private

      def add(node)
        if node.width || node.grow
          raise ArgumentError, "width and grow mean nothing in a grid: its columns share its width equally"
        end

        @children << Line.new(@styles, @columns, @column_gap) if @children.empty? || @children.last.full?
        @children.last.push(node)
        self
      end

      def description
        "a grid kept together"
      end

      def grid_gaps(gap)
        case gap
        in Numeric then [gap, gap]
        in [Numeric => line_gap, Numeric => column_gap] then [line_gap, column_gap]
        else raise ArgumentError, "gap is #{gap.inspect}: give one number, or [between lines, between columns]"
        end
      end

      # A line of a grid: a row whose cells take a column each, however many it holds.
      class Line < Row
        def initialize(styles, columns, column_gap)
          super(styles, gap: column_gap)
          @columns = columns
        end

        def push(node)
          @children << node
        end

        def full?
          @children.size == @columns
        end

        # Kept with the next line when one of its cells is, a heading in a cell for instance.
        def keep_with_next
          @children.any?(&:keep_with_next)
        end

        private

        # Cells with a background or a border are drawn as high as the line, like those of a CSS grid.
        def paint_children(prawn, child_left, top, width)
          line_height = height(prawn, width)
          @children.zip(child_widths(width)) do |child, child_width|
            if child.is_a?(Container)
              child.paint(prawn, child_left, top, child_width, line_height)
            else
              child.paint(prawn, child_left, top, child_width)
            end
            child_left += child_width + @gap
          end
        end

        def description
          "a line of a grid"
        end

        def child_widths(width)
          gaps = @gap * (@columns - 1)
          raise Prawn::Errors::CannotFit, "a grid's gaps are #{(gaps - width).round(1)} pt wider than the grid" if gaps > width

          Array.new(@children.size, (width - gaps) / @columns.to_f)
        end
      end
    end

    # Named text attributes, and what they come to for Prawn once a call's own are added.
    class Styles
      TEXT_ATTRIBUTES = %i[font size weight italic color align leading widows orphans keep_with_next].freeze
      # Attributes of the paragraph's place on the page, not of its glyphs: the layout reads them, Prawn does not.
      LAYOUT_ATTRIBUTES = %i[widows orphans keep_with_next].freeze
      FONT_STYLES = %i[normal bold italic bold_italic].freeze
      DEFAULT_STYLE = :default

      def self.check_options(given, accepted)
        unknown = given.keys - accepted
        return if unknown.empty?

        raise ArgumentError, "unknown option#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}: " \
          "accepted options are #{accepted.map(&:inspect).join(", ")}"
      end

      # Prawn's name for a weight and a slant.
      def self.font_style(weight, italic)
        weight ||= :normal
        raise ArgumentError, "weight is #{weight.inspect}: accepted weights are :normal, :bold" unless %i[normal bold].include?(weight)

        FONT_STYLES[((weight == :bold) ? 1 : 0) + (italic ? 2 : 0)]
      end

      def initialize(prawn, default_font_features)
        @prawn = prawn
        @default_font_features = default_font_features
        @attributes_by_name = {}
      end

      def define(name, attributes)
        self.class.check_options(attributes, TEXT_ATTRIBUTES)
        @attributes_by_name[name] = attributes.freeze
      end

      # The default style's font, size and colour, which a table's cells start from.
      def cell_defaults
        @attributes_by_name.fetch(DEFAULT_STYLE, {}).slice(:font, :size, :color)
      end

      # The font to set around the text, if any, and the options of the Prawn call.
      def text_arguments(style, attributes)
        self.class.check_options(attributes, TEXT_ATTRIBUTES)
        attributes = {**@attributes_by_name.fetch(DEFAULT_STYLE, {}), **named(style), **attributes}
        layout = attributes.slice(*LAYOUT_ATTRIBUTES)
        attributes = attributes.except(*LAYOUT_ATTRIBUTES)
        font = attributes.delete(:font)
        font_options = (font.nil? || @prawn.font_families.key?(font)) ? {} : {features: @default_font_features}
        {font:, font_options:, color: attributes.delete(:color), text_options: text_options(attributes), **layout}
      end

      private

      def named(name)
        return {} unless name

        @attributes_by_name.fetch(name) do
          raise ArgumentError, "unknown style #{name.inspect}: defined styles are #{@attributes_by_name.keys.map(&:inspect).join(", ")}"
        end
      end

      def text_options(attributes)
        font_style = self.class.font_style(attributes.delete(:weight), attributes.delete(:italic))
        attributes[:style] = font_style unless font_style == :normal
        attributes.compact
      end
    end
  end
end
