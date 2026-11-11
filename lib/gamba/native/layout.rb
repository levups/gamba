# frozen_string_literal: true

module Gamba
  # Boxes described first, measured, then placed: a stack puts its children one under the other and breaks pages
  # between them, a row puts them side by side on one page.
  module Layout
    FIT_TOLERANCE_POINTS = 0.001
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

      def next_page
        @prawn.bounds.move_past_bottom
        @page_top = @y = @prawn.y
      end
    end

    class Node
      OPTIONS = %i[width grow].freeze

      attr_reader :width, :grow

      def initialize(width: nil, grow: nil)
        raise ArgumentError, "width and grow exclude each other: a box is as wide as told, or shares what is left" if width && grow

        @width = width
        @grow = grow
      end

      # A box is measured when it is placed and again by the boxes around it: once per width is enough.
      def height(prawn, width)
        (@height_by_width ||= {})[width] ||= measure(prawn, width)
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

    class Text < Node
      def initialize(string, font:, font_options:, color:, text_options:, **)
        super(**)
        @fragments = [color ? {text: string, color:} : {text: string}]
        @font = font
        @font_options = font_options
        @text_options = text_options
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

      # Lines fill the page, and the rest goes on to the next ones.
      def flow(prawn, cursor, left, width)
        with_font(prawn) do
          fragments = @fragments
          loop do
            box = box(prawn, fragments, relative(prawn, left, cursor.y), width, cursor.remaining)
            unprinted = box.render
            cursor.y -= advance(box) unless box.nothing_printed?
            break if unprinted.empty?
            raise Prawn::Errors::CannotFit, "#{description} has a line higher than the page" if box.nothing_printed? && cursor.at_page_top?

            fragments = unprinted
            cursor.next_page
          end
        end
      end

      private

      def measure(prawn, width)
        with_font(prawn) do
          @measured_width = width
          @measured_box = box(prawn, @fragments, [0, 0], width, MEASURING_HEIGHT_POINTS)
          @measured_box.render(dry_run: true, keep_layout: true)
          advance(@measured_box)
        end
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

    # What a document and its containers share: the calls that add a box.
    module Builder
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

      private

      def add(node)
        @children << node
        self
      end

      def decorated?
        @background || @border_width
      end

      def decorate(prawn, left, top, width, height)
        return unless decorated?

        prawn.save_graphics_state do
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

      def paint(prawn, left, top, width)
        decorate(prawn, left, top, width, height(prawn, width))
        child_top = top - @padding_top
        @children.each do |child|
          child_width = child_width(child, width)
          child.paint(prawn, left + @padding_left, child_top, child_width)
          child_top -= child.height(prawn, child_width) + @gap
        end
      end

      # A plain stack breaks pages between its children; one kept together, or with a background or a border to
      # draw around the whole of it, moves as one box.
      def flow(prawn, cursor, left, width)
        return super if @keep_together || decorated?

        cursor.y -= @padding_top
        @children.each_with_index do |child, index|
          cursor.y -= @gap unless index.zero? || cursor.at_page_top?
          child.flow(prawn, cursor, left + @padding_left, child_width(child, width))
        end
        cursor.y -= @padding_bottom
      end

      private

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

    class Row < Container
      def initialize(styles, **options)
        Styles.check_options(options, OPTIONS)
        super
      end

      def paint(prawn, left, top, width)
        decorate(prawn, left, top, width, height(prawn, width))
        child_left = left + @padding_left
        @children.zip(child_widths(width)) do |child, child_width|
          child.paint(prawn, child_left, top - @padding_top, child_width)
          child_left += child_width + @gap
        end
      end

      private

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

    # Named text attributes, and what they come to for Prawn once a call's own are added.
    class Styles
      TEXT_ATTRIBUTES = %i[font size weight italic color align leading].freeze
      FONT_STYLES = %i[normal bold italic bold_italic].freeze
      DEFAULT_STYLE = :default

      def self.check_options(given, accepted)
        unknown = given.keys - accepted
        return if unknown.empty?

        raise ArgumentError, "unknown option#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}: " \
          "accepted options are #{accepted.map(&:inspect).join(", ")}"
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

      # The font to set around the text, if any, and the options of the Prawn call.
      def text_arguments(style, attributes)
        self.class.check_options(attributes, TEXT_ATTRIBUTES)
        attributes = {**@attributes_by_name.fetch(DEFAULT_STYLE, {}), **named(style), **attributes}
        font = attributes.delete(:font)
        font_options = (font.nil? || @prawn.font_families.key?(font)) ? {} : {features: @default_font_features}
        {font:, font_options:, color: attributes.delete(:color), text_options: text_options(attributes)}
      end

      private

      def named(name)
        return {} unless name

        @attributes_by_name.fetch(name) do
          raise ArgumentError, "unknown style #{name.inspect}: defined styles are #{@attributes_by_name.keys.map(&:inspect).join(", ")}"
        end
      end

      def text_options(attributes)
        weight = attributes.delete(:weight) || :normal
        raise ArgumentError, "weight is #{weight.inspect}: accepted weights are :normal, :bold" unless %i[normal bold].include?(weight)

        font_style = FONT_STYLES[((weight == :bold) ? 1 : 0) + (attributes.delete(:italic) ? 2 : 0)]
        attributes[:style] = font_style unless font_style == :normal
        attributes.compact
      end
    end
  end
end
