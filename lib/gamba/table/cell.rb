# frozen_string_literal: true

require "date"

module Prawn
  class Document
    def cell(options = {})
      cell = Table::Cell.make(self, options.delete(:content), options)
      cell.draw
      cell
    end

    def make_cell(content, options = {})
      Table::Cell.make(self, content, options)
    end

    # Runs the block, then puts back the listed attributes as they were.
    def mask(*fields)
      stored = fields.to_h { |field| [field, public_send(field)] }
      yield
      stored.each { |field, value| public_send(:"#{field}=", value) }
    end
  end

  class Table
    class Cell
      # Extra width given to a cell's content box, so text measured to fit exactly is not wrapped.
      FPTolerance = 1 # rubocop:disable Naming/ConstantName -- Prawn::Table's public name
      SIDE_INDEX = {top: 0, right: 1, bottom: 2, left: 3}.freeze

      attr_reader :padding, :colspan, :rowspan, :dummy_cells, :border_widths, :border_colors, :border_lines
      attr_writer :height
      attr_accessor :borders, :content, :background_color

      def self.make(pdf, content, options = {})
        at = options.delete(:at) || [0, pdf.cursor]
        content = content.to_s if content.nil? || content.is_a?(Numeric) || content.is_a?(Date)
        if content.is_a?(Hash)
          return Cell::Image.new(pdf, at, content) if content[:image]

          options.update(content)
          content = options[:content]
        else
          options[:content] = content
        end
        options[:content] = content = "" if content.nil?

        case content
        when Cell then content
        when String then Cell::Text.new(pdf, at, options)
        when Table then Cell::Subtable.new(pdf, at, options)
        when Array then Cell::Subtable.new(pdf, at, options.merge(content: Table.new(options[:content], pdf, {})))
        else raise Errors::UnrecognizedTableContent
        end
      end

      def self.draw_cells(cells)
        cells.each do |cell, point|
          cell.set_width_constraints
          cell.draw_background(point)
        end
        cells.each do |cell, point|
          cell.draw_borders(point)
          cell.draw_bounded_content(point)
        end
      end

      def initialize(pdf, point, options = {})
        @pdf = pdf
        @point = point
        @padding = [5, 5, 5, 5]
        @borders = %i[top bottom left right]
        @border_widths = [1] * 4
        @border_colors = ["000000"] * 4
        @border_lines = [:solid] * 4
        @colspan = 1
        @rowspan = 1
        @dummy_cells = []
        options.each { |key, value| send(:"#{key}=", value) }
        @initializer_run = true
      end

      def min_width_ignoring_span
        set_width_constraints
        @min_width
      end

      def min_width
        return min_width_ignoring_span if @colspan == 1

        min_widths = Hash.new(0)
        dummy_cells.each { |dummy| min_widths[dummy.column] = [min_widths[dummy.column], dummy.min_width].max }
        min_widths[column] = [min_widths[column], min_width_ignoring_span].max
        min_widths.values.sum
      end

      def avg_spanned_min_width
        min_width.to_f / colspan
      end

      def max_width_ignoring_span
        set_width_constraints
        @max_width
      end

      def max_width
        return max_width_ignoring_span if @colspan == 1

        max_widths = Hash.new(0)
        dummy_cells.each { |dummy| max_widths[dummy.column] = [max_widths[dummy.column], dummy.max_width].min }
        max_widths[column] = [max_widths[column], max_width_ignoring_span].min
        max_widths.values.sum
      end

      def style(options = {}, &block)
        options.each { |key, value| send(:"#{key}=", value) if respond_to?(:"#{key}=") }
        block&.call(self)
      end

      def width_ignoring_span
        @width || (content_width + padding_left + padding_right)
      end

      def width
        return width_ignoring_span if @colspan == 1 && @rowspan == 1

        column_widths = Hash.new(0)
        dummy_cells.each { |dummy| column_widths[dummy.column] = [column_widths[dummy.column], dummy.width].max }
        column_widths[column] = [column_widths[column], width_ignoring_span].max
        column_widths.values.sum
      end

      def width=(width)
        @width = @min_width = @max_width = width
      end

      def content_width
        return @width - padding_left - padding_right if @width

        natural_content_width
      end

      def spanned_content_width
        width - padding_left - padding_right
      end

      def natural_content_width
        raise NotImplementedError, "subclasses must implement natural_content_width"
      end

      def height_ignoring_span
        @height || (content_height + padding_top + padding_bottom)
      end

      def height
        return height_ignoring_span if @colspan == 1 && @rowspan == 1

        row_heights = Hash.new(0)
        dummy_cells.each { |dummy| row_heights[dummy.row] = [row_heights[dummy.row], dummy.height].max }
        row_heights[row] = [row_heights[row], height_ignoring_span].max
        row_heights.values.sum
      end

      def content_height
        return @height - padding_top - padding_bottom if @height

        natural_content_height
      end

      def spanned_content_height
        height - padding_top - padding_bottom
      end

      def natural_content_height
        raise NotImplementedError, "subclasses must implement natural_content_height"
      end

      def colspan=(span)
        raise Errors::InvalidTableSpan, "colspan must be provided in the table's structure, never in the initialization block. See Prawn's documentation for details." if @initializer_run

        @colspan = span
      end

      def rowspan=(span)
        raise Errors::InvalidTableSpan, "rowspan must be provided in the table's structure, never in the initialization block. See Prawn's documentation for details." if @initializer_run

        @rowspan = span
      end

      def draw(point = [x, y])
        Cell.draw_cells([[self, point]])
      end

      def draw_bounded_content(point)
        @pdf.float do
          @pdf.bounding_box([point[0] + padding_left, point[1] - padding_top],
            width: spanned_content_width + FPTolerance, height: spanned_content_height + FPTolerance) { draw_content }
        end
      end

      def x
        @point[0]
      end

      def x=(value)
        @point[0] = value
      end

      def relative_x
        x + @pdf.bounds.left_side - @pdf.bounds.absolute_left
      end

      def y
        @point[1]
      end

      def y=(value)
        @point[1] = value
      end

      def relative_y(offset = 0)
        y + offset - @pdf.bounds.absolute_bottom
      end

      def padding=(padding)
        @padding = four_sides(padding, nil => [0, 0, 0, 0], Numeric => [padding] * 4) do
          raise ArgumentError, ":padding must be a number or an array [v,h] or [t,r,b,l]"
        end
      end

      %i[top right bottom left].each_with_index do |side, index|
        define_method(:"padding_#{side}") { @padding[index] }
        define_method(:"padding_#{side}=") { |value| @padding[index] = value }
        define_method(:"border_#{side}_color") { @border_colors[index] }
        define_method(:"border_#{side}_color=") { |value| @border_colors[index] = value }
        define_method(:"border_#{side}_width") { @borders.include?(side) ? @border_widths[index] : 0 }
        define_method(:"border_#{side}_width=") { |value| @border_widths[index] = value }
        define_method(:"border_#{side}_line") { @borders.include?(side) ? @border_lines[index] : 0 }
        define_method(:"border_#{side}_line=") { |value| @border_lines[index] = value }
      end

      def border_color=(color)
        @border_colors = four_sides(color, nil => ["000000"] * 4, String => [color] * 4) do
          raise ArgumentError, ":border_color must be a string or an array [v,h] or [t,r,b,l]"
        end
      end
      alias_method :border_colors=, :border_color=

      # Prawn-table resets a nil border width to four "000000": kept for compatibility.
      def border_width=(width)
        @border_widths = four_sides(width, nil => ["000000"] * 4, Numeric => [width] * 4) do
          raise ArgumentError, ":border_width must be a string or an array [v,h] or [t,r,b,l]"
        end
      end
      alias_method :border_widths=, :border_width=

      def border_line=(line)
        @border_lines =
          if line.nil? then [:solid] * 4
          elsif line.length == 1 then [line[0]] * 4
          else four_sides(line) { raise ArgumentError, "border_line must be one of :solid, :dashed, :dotted or an array [v,h] or [t,r,b,l]" }
          end
      end
      alias_method :border_lines=, :border_line=

      def set_width_constraints
        @min_width ||= padding_left + padding_right
        @max_width ||= @pdf.bounds.width
      end

      def draw_background(point)
        return unless background_color

        @pdf.mask(:fill_color) do
          @pdf.fill_color background_color
          @pdf.fill_rectangle point, width, height
        end
      end

      def draw_borders(point)
        x, y = point
        @pdf.mask(:line_width, :stroke_color) do
          @borders.each do |border|
            index = SIDE_INDEX[border]
            border_width = @border_widths[index]
            next if border_width <= 0

            from, to =
              case border
              when :top then [[x, y], [x + width, y]]
              when :bottom then [[x, y - height], [x + width, y - height]]
              when :left then [[x, y + (border_top_width / 2.0)], [x, y - height - (border_bottom_width / 2.0)]]
              when :right then [[x + width, y + (border_top_width / 2.0)], [x + width, y - height - (border_bottom_width / 2.0)]]
              end
            case @border_lines[index]
            when :dashed then @pdf.dash border_width * 4
            when :dotted then @pdf.dash border_width, space: border_width * 2
            when :solid then nil
            else raise ArgumentError, "border_line must be :solid, :dotted or :dashed"
            end
            @pdf.line_width = border_width
            @pdf.stroke_color = @border_colors[index]
            @pdf.stroke_line(from, to)
            @pdf.undash if @pdf.dashed?
          end
        end
      end

      def draw_content
        raise NotImplementedError, "subclasses must implement draw_content"
      end

      private

      # A value for each side, CSS style: one for all, [vertical, horizontal], [top, horizontal, bottom] or four.
      def four_sides(value, special_cases = {})
        special_cases.each { |kind, sides| return sides if kind.nil? ? value.nil? : kind === value }
        case value.length
        when 2 then [value[0], value[1], value[0], value[1]]
        when 3 then [value[0], value[1], value[2], value[1]]
        when 4 then [value[0], value[1], value[2], value[3]]
        else yield
        end
      end

      module InTable
        attr_accessor :row, :column
      end
    end
  end
end
