# frozen_string_literal: true

module Gamba
  module Barcodes
    # A square DataMatrix ECC 200 symbol (ISO/IEC 16022:2006) as a grid of modules: the smallest size that holds the
    # data in ASCII encodation, digits two to a codeword, other bytes past 127 behind an upper shift.
    class DataMatrix
      # Square sizes: modules on a side, data and error correction codewords, data region side, interleaved blocks.
      Size = Data.define(:modules, :data, :ecc, :region, :blocks)
      SIZES = [
        [10, 3, 5, 8, 1], [12, 5, 7, 10, 1], [14, 8, 10, 12, 1], [16, 12, 12, 14, 1], [18, 18, 14, 16, 1],
        [20, 22, 18, 18, 1], [22, 30, 20, 20, 1], [24, 36, 24, 22, 1], [26, 44, 28, 24, 1], [32, 62, 36, 14, 1],
        [36, 86, 42, 16, 1], [40, 114, 48, 18, 1], [44, 144, 56, 20, 1], [48, 174, 68, 22, 1], [52, 204, 84, 24, 2],
        [64, 280, 112, 14, 2], [72, 368, 144, 16, 4], [80, 456, 192, 18, 4], [88, 576, 224, 20, 4],
        [96, 696, 272, 22, 4], [104, 816, 336, 24, 6], [120, 1050, 408, 18, 6], [132, 1304, 496, 20, 8],
        [144, 1558, 620, 22, 10]
      ].map { |values| Size.new(*values) }.freeze
      # The light margin around the symbol, in modules (§7.7).
      QUIET_ZONE = 1
      PAD = 129
      UPPER_SHIFT = 235
      DIGIT_PAIR = 130
      # GF(2^8) modulo x^8 + x^5 + x^3 + x^2 + 1, the field of ECC 200's Reed-Solomon codes.
      EXPONENTS = Array.new(510).tap do |powers|
        value = 1
        255.times do |exponent|
          powers[exponent] = powers[exponent + 255] = value
          value <<= 1
          value ^= 0x12D if value > 0xFF
        end
      end.freeze
      LOGARITHMS = Array.new(256).tap { |logarithms| 255.times { logarithms[EXPONENTS[_1]] = _1 } }.freeze

      attr_reader :size

      def initialize(data)
        codewords = encode(data.to_s.b)
        @format = SIZES.find { _1.data >= codewords.size } ||
          raise(ArgumentError, "#{data.to_s.bytesize} bytes take #{codewords.size} codewords: a DataMatrix holds 1558 at most")
        @size = @format.modules
        codewords = pad(codewords)
        mapping = place(interleaved(codewords))
        @modules = draw(mapping)
      end

      def dark?(x, y)
        @modules[y][x]
      end

      def quiet_zone
        QUIET_ZONE
      end

      private

      def encode(bytes)
        codewords = []
        bytes.scan(/\d\d|./mn) do |chunk|
          if chunk.size == 2
            codewords << (DIGIT_PAIR + chunk.to_i)
          elsif chunk.ord < 128
            codewords << (chunk.ord + 1)
          else
            codewords << UPPER_SHIFT << (chunk.ord - 127)
          end
        end
        codewords
      end

      # The first pad is 129; the next ones are scrambled by their position, from 1 (§5.2.3).
      def pad(codewords)
        codewords << PAD if codewords.size < @format.data
        while codewords.size < @format.data
          value = PAD + (((149 * (codewords.size + 1)) % 253) + 1)
          codewords << ((value > 254) ? value - 254 : value)
        end
        codewords
      end

      # Codewords dealt to the blocks in turn, each block's error correction dealt back the same way.
      def interleaved(data)
        blocks = @format.blocks
        ecc_length = @format.ecc / blocks
        divisor = divisor(ecc_length)
        result = data.dup
        blocks.times do |block|
          remainder = remainder(data.select.with_index { |_, index| index % blocks == block }, divisor)
          remainder.each_with_index { |codeword, index| result[data.size + block + (index * blocks)] = codeword }
        end
        result
      end

      # (x - a^1)(x - a^2)…(x - a^degree), highest degree first without its leading 1.
      def divisor(degree)
        coefficients = [1]
        (1..degree).each do |root|
          next_coefficients = Array.new(coefficients.size + 1, 0)
          coefficients.each_with_index do |coefficient, index|
            next_coefficients[index] ^= coefficient
            next_coefficients[index + 1] ^= multiply(coefficient, EXPONENTS[root])
          end
          coefficients = next_coefficients
        end
        coefficients.drop(1)
      end

      def remainder(data, divisor)
        result = Array.new(divisor.size, 0)
        data.each do |codeword|
          factor = codeword ^ result.shift
          result << 0
          divisor.each_with_index { |coefficient, index| result[index] ^= multiply(coefficient, factor) }
        end
        result
      end

      def multiply(x, y)
        (x.zero? || y.zero?) ? 0 : EXPONENTS[LOGARITHMS[x] + LOGARITHMS[y]]
      end

      # The data regions put together, filled by the standard's diagonal placement (Annex F).
      def place(codewords)
        @rows = @columns = (@size / (@format.region + 2)) * @format.region
        @mapping = Array.new(@rows * @columns)
        @codewords = codewords
        character = 0
        row = 4
        column = 0
        loop do
          corner(character += 1, CORNER_1) if row == @rows && column.zero?
          corner(character += 1, CORNER_2) if row == @rows - 2 && column.zero? && @columns % 4 != 0
          corner(character += 1, CORNER_3) if row == @rows - 2 && column.zero? && @columns % 8 == 4
          corner(character += 1, CORNER_4) if row == @rows + 4 && column == 2 && (@columns % 8).zero?
          loop do
            utah(row, column, character += 1) if row < @rows && column >= 0 && @mapping[(row * @columns) + column].nil?
            row -= 2
            column += 2
            break unless row >= 0 && column < @columns
          end
          row += 1
          column += 3
          loop do
            utah(row, column, character += 1) if row >= 0 && column < @columns && @mapping[(row * @columns) + column].nil?
            row += 2
            column -= 2
            break unless row < @rows && column >= 0
          end
          row += 3
          column += 1
          break unless row < @rows || column < @columns
        end
        @mapping[(@rows * @columns) - 1] = @mapping[(@rows * @columns) - @columns - 2] = true if @mapping.last.nil?
        @mapping
      end

      # Corner shapes: [row, column] of bits 1 to 8, from the far edges as negative numbers count.
      CORNER_1 = [[-1, 0], [-1, 1], [-1, 2], [0, -2], [0, -1], [1, -1], [2, -1], [3, -1]].freeze
      CORNER_2 = [[-3, 0], [-2, 0], [-1, 0], [0, -4], [0, -3], [0, -2], [0, -1], [1, -1]].freeze
      CORNER_3 = [[-3, 0], [-2, 0], [-1, 0], [0, -2], [0, -1], [1, -1], [2, -1], [3, -1]].freeze
      CORNER_4 = [[-1, 0], [-1, -1], [0, -3], [0, -2], [0, -1], [1, -3], [1, -2], [1, -1]].freeze
      UTAH = [[-2, -2], [-2, -1], [-1, -2], [-1, -1], [-1, 0], [0, -2], [0, -1], [0, 0]].freeze

      def corner(character, shape)
        shape.each_with_index do |(row, column), bit|
          module_at(row.negative? ? @rows + row : row, column.negative? ? @columns + column : column, character, bit)
        end
      end

      def utah(row, column, character)
        UTAH.each_with_index { |(dy, dx), bit| module_at(row + dy, column + dx, character, bit) }
      end

      # Bit 0 is the codeword's most significant; positions off the edges wrap as the standard says.
      def module_at(row, column, character, bit)
        if row.negative?
          row += @rows
          column += 4 - ((@rows + 4) % 8)
        end
        if column.negative?
          column += @columns
          row += 4 - ((@columns + 4) % 8)
        end
        codeword = @codewords[character - 1]
        @mapping[(row * @columns) + column] = !codeword.nil? && codeword[7 - bit] == 1
      end

      # Each data region framed by its finder: solid left and bottom edges, alternating top and right ones.
      def draw(mapping)
        side = @format.region
        Array.new(@size) do |y|
          Array.new(@size) do |x|
            region_y, inner_y = y.divmod(side + 2)
            region_x, inner_x = x.divmod(side + 2)
            if inner_x.zero? || inner_y == side + 1 then true
            elsif inner_y.zero? then inner_x.even?
            elsif inner_x == side + 1 then inner_y.odd?
            else mapping[(((region_y * side) + inner_y - 1) * @columns) + (region_x * side) + inner_x - 1]
            end
          end
        end
      end
    end
  end
end
