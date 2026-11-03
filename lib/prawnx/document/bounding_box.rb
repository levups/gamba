# frozen_string_literal: true

module Prawn
  class Document
    def bounding_box(point, *arguments, &block)
      init_bounding_box(block) do |parent_box|
        @bounding_box = BoundingBox.new(self, parent_box, map_to_absolute(point), *arguments)
      end
    end

    def canvas(&block)
      init_bounding_box(block, hold_position: true) do
        _left, _bottom, page_width, page_height = page.dimensions
        @bounding_box = BoundingBox.new(self, nil, [0, page_height], width: page_width, height: page_height)
      end
    end

    private

    def init_bounding_box(user_block, options = {})
      raise ArgumentError, "bounding boxes require a block to be drawn within the box" unless user_block

      parent_box = @bounding_box
      original_y = y
      yield parent_box
      self.y = @bounding_box.absolute_top
      user_block.call
      self.y = original_y if y == @bounding_box.absolute_top
      self.y = @bounding_box.absolute_bottom unless options[:hold_position] || @bounding_box.stretchy?
      created_box = @bounding_box
      @bounding_box = parent_box
      created_box
    end

    # A rectangle the document draws into, positioned from its top left corner; without a height, it stretches
    # down to wherever the cursor ends.
    class BoundingBox
      class NoReferenceBounds < StandardError
        def initialize(message = "Can't find reference bounds: my parent is unset")
          super
        end
      end

      attr_reader :document, :parent, :total_left_padding, :total_right_padding, :width

      def initialize(document, parent, point, options = {})
        raise ArgumentError, "BoundingBox needs the :width option to be set" unless options[:width]

        @document = document
        @parent = parent
        @x, @y = point
        @width = options[:width]
        @height = options[:height]
        @total_left_padding = 0
        @total_right_padding = 0
        @stretched_height = nil
      end

      def anchor
        [@x, @y - height]
      end

      def indent(left_padding, right_padding = 0)
        add_left_padding(left_padding)
        add_right_padding(right_padding)
        yield
      ensure
        @document.bounds.subtract_left_padding(left_padding)
        @document.bounds.subtract_right_padding(right_padding)
      end

      def add_left_padding(left_padding)
        @total_left_padding += left_padding
        @x += left_padding
        @width -= left_padding
      end

      def subtract_left_padding(left_padding)
        @total_left_padding -= left_padding
        @x -= left_padding
        @width += left_padding
      end

      def add_right_padding(right_padding)
        @total_right_padding += right_padding
        @width -= right_padding
      end

      def subtract_right_padding(right_padding)
        @total_right_padding -= right_padding
        @width += right_padding
      end

      def left
        0
      end

      def right
        @width
      end

      def top
        height
      end

      def bottom
        0
      end

      def top_left
        [left, top]
      end

      def top_right
        [right, top]
      end

      def bottom_right
        [right, bottom]
      end

      def bottom_left
        [left, bottom]
      end

      def absolute_left
        @x
      end

      def absolute_right
        @x + width
      end

      def absolute_top
        @y
      end

      def absolute_bottom
        @y - height
      end

      def absolute_top_left
        [absolute_left, absolute_top]
      end

      def absolute_top_right
        [absolute_right, absolute_top]
      end

      def absolute_bottom_left
        [absolute_left, absolute_bottom]
      end

      def absolute_bottom_right
        [absolute_right, absolute_bottom]
      end

      def height
        return @height if @height

        @stretched_height = [absolute_top - @document.y, Float(@stretched_height || 0.0)].max
      end
      alias_method :update_height, :height

      def left_side
        absolute_left
      end

      def right_side
        absolute_right
      end

      def move_past_bottom
        if @document.page_number == @document.page_count
          @document.start_new_page
        else
          @document.go_to_page(@document.page_number + 1)
        end
      end

      def stretchy?
        !@height
      end

      def reference_bounds
        return self unless stretchy?
        raise NoReferenceBounds unless @parent

        @parent.reference_bounds
      end
    end
  end
end
