# frozen_string_literal: true

module Prawn
  class Document
    def column_box(*arguments, &block)
      init_column_box(block) do |parent_box|
        map_to_absolute!(arguments[0])
        @bounding_box = ColumnBox.new(self, parent_box, *arguments)
      end
    end

    private

    def init_column_box(user_block, options = {})
      parent_box = @bounding_box
      yield parent_box
      self.y = @bounding_box.absolute_top
      user_block.call
      self.y = @bounding_box.absolute_bottom unless options[:hold_position]
      @bounding_box = parent_box
    end

    # A bounding box whose text flows down one column, then the next, then onto a new page.
    class ColumnBox < BoundingBox
      DEFAULT_COLUMN_COUNT = 3

      def initialize(document, parent, point, options = {})
        super
        @columns = options[:columns] || DEFAULT_COLUMN_COUNT
        @spacer = options[:spacer] || @document.font_size
        @current_column = 0
        @reflow_margins = options[:reflow_margins]
      end

      def bare_column_width
        (@width - (@spacer * (@columns - 1))) / @columns
      end

      def width
        bare_column_width - (@total_left_padding + @total_right_padding)
      end

      def width_of_column
        bare_column_width + @spacer
      end

      def left_side
        absolute_left + (width_of_column * @current_column)
      end

      def left
        width_of_column * @current_column
      end

      def right_side
        absolute_right - (width_of_column * (@columns - (1 + @current_column)))
      end

      def right
        left + width
      end

      def move_past_bottom
        @current_column = (@current_column + 1) % @columns
        @document.y = @y
        return unless @current_column.zero?

        @y = @parent.absolute_top if @reflow_margins
        @document.start_new_page
      end

      def add_left_padding(left_padding)
        @total_left_padding += left_padding
        @x += left_padding
      end

      def subtract_left_padding(left_padding)
        @total_left_padding -= left_padding
        @x -= left_padding
      end

      def add_right_padding(right_padding)
        @total_right_padding += right_padding
      end

      def subtract_right_padding(right_padding)
        @total_right_padding -= right_padding
      end
    end
  end
end
