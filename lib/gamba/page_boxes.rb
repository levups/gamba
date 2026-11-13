# frozen_string_literal: true

module Gamba
  # The boxes and the turn of a page read from a PDF written elsewhere, through @reader, whatever the file holds:
  # a value that is not a usable box or number reads as missing.
  module PageBoxes
    DEFAULT_MEDIA_BOX = [0.0, 0.0, 612.0, 792.0].freeze
    # What draws a page's content turned as a viewer shows it under /Rotate, in a box from the origin.
    ROTATIONS = {
      90 => ->(width, height) { [0.0, -1.0, 1.0, 0.0, 0.0, width] },
      180 => ->(width, height) { [-1.0, 0.0, 0.0, -1.0, width, height] },
      270 => ->(width, height) { [0.0, 1.0, -1.0, 0.0, height, 0.0] }
    }.freeze

    private

    def media_box(page)
      box(page[:MediaBox]) || DEFAULT_MEDIA_BOX
    end

    # What a viewer shows: the crop box within the media box.
    def visible_box(page)
      media = media_box(page)
      crop = box(page[:CropBox])
      crop ? intersection(crop, media) : media
    end

    # 0, 90, 180 or 270: a turn that is not a quarter one reads as none.
    def rotation(page)
      rotation = number(page[:Rotate]).to_i % 360
      (rotation % 90).zero? ? rotation : 0
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

    def number(value)
      numeric(@reader.resolve(value))
    end

    # A real too large for a Float reads as infinite, and would write NaN into the page's matrix: no number then.
    def numeric(value)
      number = (value.is_a?(PDF::Core::Real) || value.is_a?(Numeric)) ? value.to_f : nil
      number if number&.finite?
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
  end
end
