# frozen_string_literal: true

module Prawn
  class Document
    def define_grid(options = {})
      @boxes = nil
      @grid = Grid.new(self, options)
    end

    def grid(*arguments)
      @boxes ||= {}
      @boxes[arguments] ||=
        if arguments.empty?
          @grid
        else
          first, second = arguments
          if first.is_a?(Array) && second.is_a?(Array) && first.length == 2 && second.length == 2
            MultiBox.new(self, GridBox.new(self, *first), GridBox.new(self, *second))
          else
            GridBox.new(self, first, second)
          end
        end
    end

    # Rows and columns of equal size dividing the current bounds, separated by gutters.
    class Grid
      attr_reader :pdf, :columns, :rows, :gutter, :row_gutter, :column_gutter

      def initialize(pdf, options = {})
        Prawn.verify_options(%i[columns rows gutter row_gutter column_gutter], options)
        @pdf = pdf
        @columns = options[:columns]
        @rows = options[:rows]
        if options.key?(:gutter)
          @gutter = Float(options[:gutter])
          @row_gutter = @gutter
          @column_gutter = @gutter
        else
          @row_gutter = Float(options[:row_gutter])
          @column_gutter = Float(options[:column_gutter])
          @gutter = 0
        end
      end

      def column_width
        @column_width ||= subdivide(pdf.bounds.width, columns, column_gutter)
      end

      def row_height
        @row_height ||= subdivide(pdf.bounds.height, rows, row_gutter)
      end

      def show_all(color = "CCCCCC")
        rows.times { |row| columns.times { |column| pdf.grid(row, column).show(color) } }
      end

      private

      def subdivide(total, count, gutter)
        (Float(total) - (gutter * Float(count - 1))) / Float(count)
      end
    end

    # What a grid cell and a span of cells share: corners, a bounding box, and a way to show themselves.
    module GridArea
      def top_left
        [left, top]
      end

      def top_right
        [right, top]
      end

      def bottom_left
        [left, bottom]
      end

      def bottom_right
        [right, bottom]
      end

      def bounding_box(&)
        pdf.bounding_box(top_left, width:, height:, &)
      end

      def show(grid_color = "CCCCCC")
        bounding_box do
          original_stroke_color = pdf.stroke_color
          pdf.stroke_color = grid_color
          pdf.text(name)
          pdf.stroke_bounds
          pdf.stroke_color = original_stroke_color
        end
      end
    end

    class GridBox
      include GridArea

      attr_reader :pdf

      def initialize(pdf, rows, columns)
        @pdf = pdf
        @rows = rows
        @columns = columns
      end

      def name
        "#{@rows},#{@columns}"
      end

      def total_height
        Float(pdf.bounds.height)
      end

      def width
        Float(grid.column_width)
      end

      def height
        Float(grid.row_height)
      end

      def gutter
        Float(grid.gutter)
      end

      def left
        @left ||= (width + grid.column_gutter) * Float(@columns)
      end

      def right
        @right ||= left + width
      end

      def top
        @top ||= total_height - ((height + grid.row_gutter) * Float(@rows))
      end

      def bottom
        @bottom ||= top - height
      end

      private

      def grid
        pdf.grid
      end
    end

    class MultiBox
      include GridArea

      attr_reader :pdf

      def initialize(pdf, box1, box2)
        @pdf = pdf
        @boxes = [box1, box2]
      end

      def name
        @boxes.map(&:name).join(":")
      end

      def total_height
        @boxes[0].total_height
      end

      def width
        right_box.right - left_box.left
      end

      def height
        top_box.top - bottom_box.bottom
      end

      def gutter
        @boxes[0].gutter
      end

      def left
        left_box.left
      end

      def right
        right_box.right
      end

      def top
        top_box.top
      end

      def bottom
        bottom_box.bottom
      end

      private

      def left_box
        @left_box ||= @boxes.min_by(&:left)
      end

      def right_box
        @right_box ||= @boxes.max_by(&:right)
      end

      def top_box
        @top_box ||= @boxes.max_by(&:top)
      end

      def bottom_box
        @bottom_box ||= @boxes.min_by(&:bottom)
      end
    end
  end
end
