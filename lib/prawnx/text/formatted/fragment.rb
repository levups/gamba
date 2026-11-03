# frozen_string_literal: true

module Prawn
  module Text
    module Formatted
      # A run of text sharing one format on one line, with its measurements and, once drawn, its position.
      class Fragment
        attr_reader :format_state, :text
        attr_writer :width
        attr_accessor :line_height, :descender, :ascender, :word_spacing, :left, :baseline

        def initialize(text, format_state, document)
          @format_state = format_state
          @document = document
          @word_spacing = 0
          @original_text = text
          @text = process_text(@original_text)
        end

        def width
          @word_spacing.zero? ? @width : @width + (@word_spacing * space_count)
        end

        def height
          top - bottom
        end

        def subscript?
          styles.include?(:subscript)
        end

        def superscript?
          styles.include?(:superscript)
        end

        def y_offset
          if subscript? then -descender
          elsif superscript? then 0.85 * ascender
          else 0
          end
        end

        def bounding_box
          [left, bottom, right, top]
        end

        def absolute_bounding_box
          left, bottom, right, top = bounding_box
          bounds = @document.bounds
          [left + bounds.absolute_left, bottom + bounds.absolute_bottom, right + bounds.absolute_left, top + bounds.absolute_bottom]
        end

        def underline_points
          y = baseline - 1.25
          [[left, y], [right, y]]
        end

        def strikethrough_points
          y = baseline + (ascender * 0.3)
          [[left, y], [right, y]]
        end

        def styles
          @format_state[:styles] || []
        end

        def link
          @format_state[:link]
        end

        def anchor
          @format_state[:anchor]
        end

        def local
          @format_state[:local]
        end

        def color
          @format_state[:color]
        end

        def font
          @format_state[:font]
        end

        def size
          @format_state[:size]
        end

        def character_spacing
          @format_state[:character_spacing] || @document.character_spacing
        end

        def direction
          @format_state[:direction]
        end

        def default_direction=(direction)
          return if @format_state[:direction]

          @format_state[:direction] = direction
          @text = process_text(@original_text)
        end

        def include_trailing_white_space!
          @format_state.delete(:exclude_trailing_white_space)
          @text = process_text(@original_text)
        end

        def space_count
          @text.count(" ")
        end

        def callback_objects
          callback = @format_state[:callback]
          callback.nil? ? [] : Array(callback)
        end

        def right
          left + width
        end

        def top
          baseline + ascender
        end

        def bottom
          baseline - descender
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
          absolute_bounding_box[0]
        end

        def absolute_right
          absolute_bounding_box[2]
        end

        def absolute_top
          absolute_bounding_box[3]
        end

        def absolute_bottom
          absolute_bounding_box[1]
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

        private

        def process_text(text)
          string = (text.encoding == ::Encoding::UTF_8) ? text.gsub(ZWSP, "") : text
          if @format_state[:exclude_trailing_white_space]
            string = string.rstrip
            string = process_soft_hyphens(string[0..-2]) + string[-1..] if soft_hyphens_need_processing?(string)
          elsif soft_hyphens_need_processing?(string)
            string = process_soft_hyphens(string)
          end
          (direction == :rtl) ? string.reverse : string
        end

        def soft_hyphens_need_processing?(string)
          !string.empty? && @format_state[:normalized_soft_hyphen]
        end

        def process_soft_hyphens(string)
          soft_hyphen = @format_state[:normalized_soft_hyphen]
          string = string.dup.force_encoding(soft_hyphen.encoding) if string.encoding != soft_hyphen.encoding
          string.gsub(soft_hyphen, "")
        end
      end
    end
  end
end
