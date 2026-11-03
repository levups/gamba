# frozen_string_literal: true

module PrawnX
  module TrueType
    # A Compact Font Format program (Adobe Technical Note #5176) keeping only the outlines a document uses: other
    # glyphs become an empty charstring, so glyph indices and subroutines stay where they were.
    class CffSubset
      ENDCHAR = "\x0E".b
      CHARSTRINGS = [17].freeze
      PRIVATE = [18].freeze
      CHARSET = [15].freeze
      ENCODING = [16].freeze
      FD_ARRAY = [12, 36].freeze
      FD_SELECT = [12, 37].freeze
      # Offsets 0 to 2 of charset and Encoding name predefined tables, not places in the font.
      PREDEFINED_TABLE_LIMIT = 2
      FIVE_BYTE_INTEGER = 29

      def initialize(cff)
        @cff = cff.b
      end

      def bytes(glyphs_kept)
        build(glyphs_kept)
      rescue *File::MALFORMED_FONT_ERRORS => exception
        raise Error, "Malformed CFF font program: #{exception.message}"
      end

      private

      def build(glyphs_kept)
        header_size = @cff.getbyte(2)
        _names, names_end = read_index(header_size)
        top_dicts, top_end = read_index(names_end)
        top_operators = parse_dict(top_dicts.first)

        old_charstrings_offset = operands(top_operators, CHARSTRINGS).first
        charstrings, = read_index(old_charstrings_offset)
        kept = glyphs_kept.to_h { [_1, true] }
        new_charstrings = charstrings.each_with_index.map { |charstring, glyph| kept[glyph] ? charstring : ENDCHAR }

        font_dicts = nil
        if (fd_array_offset = operands(top_operators, FD_ARRAY).first)
          font_dicts = read_index(fd_array_offset).first.map { parse_dict(_1) }
        end

        # Every offset operand is written as a five-byte integer, so the new Top DICT's size is known before its
        # offsets are: everything after it then moves by the same delta.
        placeholder_top = encode_dict(relocated(top_operators, 0, 0, 0))
        delta = index([placeholder_top]).bytesize - (top_end - names_end)
        tail = @cff.byteslice(top_end..)
        charstrings_offset = top_end + delta + tail.bytesize
        appended = index(new_charstrings)
        fd_array_new_offset = nil
        if font_dicts
          fd_array_new_offset = charstrings_offset + appended.bytesize
          appended += index(font_dicts.map { encode_dict(relocated(_1, delta, nil, nil)) })
        end
        new_top = encode_dict(relocated(top_operators, delta, charstrings_offset, fd_array_new_offset))
        @cff.byteslice(0, names_end) + index([new_top]) + tail + appended
      end

      def read_index(offset)
        count = @cff.unpack1("@#{offset} n")
        return [[], offset + 2] if count.zero?

        offset_size = @cff.getbyte(offset + 2)
        offsets = Array.new(count + 1) { read_offset(offset + 3 + (_1 * offset_size), offset_size) }
        data_start = offset + 3 + ((count + 1) * offset_size) - 1
        items = offsets.each_cons(2).map { |first, last| @cff.byteslice(data_start + first, last - first) }
        [items, data_start + offsets.last]
      end

      def read_offset(position, size)
        @cff.byteslice(position, size).bytes.inject(0) { (_1 << 8) | _2 }
      end

      def index(items)
        return [0].pack("n") if items.empty?

        offsets = items.each_with_object([1]) { |item, list| list << (list.last + item.bytesize) }
        offset_size = [1, 2, 3, 4].find { offsets.last < (1 << (8 * _1)) }
        packed_offsets = offsets.map { [_1].pack("N").byteslice(4 - offset_size, offset_size) }.join
        [items.size].pack("n") + offset_size.chr + packed_offsets + items.join.b
      end

      # [operator bytes, operand values, raw operand bytes] in order.
      def parse_dict(data)
        entries = []
        operands = []
        raw_start = 0
        position = 0
        while position < data.bytesize
          byte = data.getbyte(position)
          if byte <= 21
            operator = (byte == 12) ? [12, data.getbyte(position + 1)] : [byte]
            position += operator.size
            entries << [operator, operands, data.byteslice(raw_start, position - operator.size - raw_start)]
            operands = []
            raw_start = position
          else
            value, size = read_operand(data, position)
            operands << value
            position += size
          end
        end
        entries
      end

      def read_operand(data, position)
        byte = data.getbyte(position)
        case byte
        when 28 then [data.unpack1("@#{position + 1} s>"), 3]
        when 29 then [data.unpack1("@#{position + 1} l>"), 5]
        when 30
          size = 1
          loop do
            nibbles = data.getbyte(position + size)
            size += 1
            break if (nibbles >> 4) == 0x0F || (nibbles & 0x0F) == 0x0F
          end
          [:real, size]
        when 32..246 then [byte - 139, 1]
        when 247..250 then [((byte - 247) * 256) + data.getbyte(position + 1) + 108, 2]
        when 251..254 then [(-(byte - 251) * 256) - data.getbyte(position + 1) - 108, 2]
        else raise Error, "Unexpected byte #{byte} in a CFF dictionary"
        end
      end

      def operands(entries, operator)
        entries.find { _1[0] == operator }&.dig(1) || []
      end

      # Offsets into the font move by delta; CharStrings and FDArray point at their new copies at the end.
      def relocated(entries, delta, charstrings_offset, fd_array_offset)
        entries.map do |operator, values, raw|
          new_values =
            case operator
            when CHARSTRINGS then charstrings_offset && [charstrings_offset]
            when FD_ARRAY then fd_array_offset && [fd_array_offset]
            when PRIVATE then [values[0], values[1] + delta]
            when CHARSET, ENCODING then [(values[0] > PREDEFINED_TABLE_LIMIT) ? values[0] + delta : values[0]]
            when FD_SELECT then [values[0] + delta]
            end
          [operator, new_values, raw]
        end
      end

      def encode_dict(entries)
        entries.each_with_object(+"".b) do |(operator, new_values, raw), dict|
          dict << (new_values ? new_values.map { [FIVE_BYTE_INTEGER, _1].pack("Cl>") }.join : raw)
          dict << operator.pack("C*")
        end
      end
    end
  end
end
