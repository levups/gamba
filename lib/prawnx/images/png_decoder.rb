# frozen_string_literal: true

module Prawn
  module Images
    # Undoes PNG's per-row filters (PNG specification §9), giving back raw samples: needed to split an alpha
    # channel or a palette's transparency into a separate soft mask.
    module PngDecoder
      NONE = 0
      SUB = 1
      UP = 2
      AVERAGE = 3
      PAETH = 4

      module_function

      # Rows of unfiltered bytes, from the inflated data of a non-interlaced image.
      def unfilter(data, row_bytes, bytes_per_pixel)
        previous = ("\x00" * row_bytes).b
        row_count = data.bytesize / (row_bytes + 1)
        Array.new(row_count) do |row_index|
          start = row_index * (row_bytes + 1)
          filter = data.getbyte(start)
          row = data.byteslice(start + 1, row_bytes).b
          unfilter_row!(row, previous, filter, bytes_per_pixel)
          previous = row
        end
      end

      def unfilter_row!(row, previous, filter, bytes_per_pixel)
        case filter
        when NONE then nil
        when SUB
          (bytes_per_pixel...row.bytesize).each { row.setbyte(it, (row.getbyte(it) + row.getbyte(it - bytes_per_pixel)) & 0xFF) }
        when UP
          row.bytesize.times { row.setbyte(it, (row.getbyte(it) + previous.getbyte(it)) & 0xFF) }
        when AVERAGE
          row.bytesize.times do |index|
            left = (index >= bytes_per_pixel) ? row.getbyte(index - bytes_per_pixel) : 0
            row.setbyte(index, (row.getbyte(index) + ((left + previous.getbyte(index)) >> 1)) & 0xFF)
          end
        when PAETH
          row.bytesize.times do |index|
            left = (index >= bytes_per_pixel) ? row.getbyte(index - bytes_per_pixel) : 0
            up = previous.getbyte(index)
            up_left = (index >= bytes_per_pixel) ? previous.getbyte(index - bytes_per_pixel) : 0
            row.setbyte(index, (row.getbyte(index) + paeth(left, up, up_left)) & 0xFF)
          end
        else raise Errors::UnsupportedImageType, "PNG uses an unknown filter type #{filter}"
        end
        row
      end

      def paeth(left, up, up_left)
        estimate = left + up - up_left
        distance_left = (estimate - left).abs
        distance_up = (estimate - up).abs
        distance_up_left = (estimate - up_left).abs
        if distance_left <= distance_up && distance_left <= distance_up_left then left
        elsif distance_up <= distance_up_left then up
        else up_left
        end
      end
    end
  end
end
