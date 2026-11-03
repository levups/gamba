# frozen_string_literal: true

module Prawn
  class Document
    # A column of the given width across pages, positioned within the margins, starting at the cursor.
    def span(width, options = {})
      Prawn.verify_options([:position], options)
      original_position = y
      left_boundary =
        case options.fetch(:position, :left)
        when :left then margin_box.absolute_left
        when :center then margin_box.absolute_left + (margin_box.width / 2.0) - (width / 2.0)
        when :right then margin_box.absolute_right - width
        when Numeric then margin_box.absolute_left + options[:position]
        else raise ArgumentError, "Invalid option for :position"
        end
      canvas do
        bounding_box([left_boundary, margin_box.absolute_top], width:) do
          self.y = original_position
          yield
        end
      end
    end
  end
end
