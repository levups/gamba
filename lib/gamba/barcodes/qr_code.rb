# frozen_string_literal: true

module Gamba
  module Barcodes
    # A QR code (ISO/IEC 18004:2015) as a grid of modules: the smallest version that holds the text at the level of
    # error correction asked for, in numeric, alphanumeric or byte mode, UTF-8 announced by an ECI when the text
    # is not ASCII, and the mask the standard's penalty rules prefer.
    class QRCode
      LEVELS = %i[l m q h].freeze
      # The light margin scanners need around the symbol, in modules (§6.3.8).
      QUIET_ZONE = 4
      # The two bits a level writes in the format information.
      FORMAT_BITS = {l: 1, m: 0, q: 3, h: 2}.freeze
      # Per version 1 to 40: error correction codewords in each block, then the number of blocks (tables 9).
      ECC_CODEWORDS_PER_BLOCK = {
        l: [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        m: [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        q: [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        h: [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
      }.freeze
      BLOCKS = {
        l: [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        m: [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        q: [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        h: [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
      }.freeze
      ALPHANUMERIC = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
      ALPHANUMERIC_VALUES = ALPHANUMERIC.each_char.with_index.to_h.freeze
      # Mode indicator and character count bits for versions 1-9, 10-26 and 27-40.
      MODES = {numeric: [0x1, [10, 12, 14]], alphanumeric: [0x2, [9, 11, 13]], byte: [0x4, [8, 16, 16]]}.freeze
      VERSION_RANGES = [1..9, 10..26, 27..40].freeze
      ECI_MODE = 0x7
      UTF8_ECI = 26
      PAD_BYTES = [0xEC, 0x11].freeze
      MASKS = [
        ->(x, y) { (x + y).even? },
        ->(_x, y) { y.even? },
        ->(x, _y) { (x % 3).zero? },
        ->(x, y) { ((x + y) % 3).zero? },
        ->(x, y) { ((x / 3) + (y / 2)).even? },
        ->(x, y) { ((x * y) % 2) + ((x * y) % 3) == 0 },
        ->(x, y) { (((x * y) % 2) + ((x * y) % 3)).even? },
        ->(x, y) { (((x + y) % 2) + ((x * y) % 3)).even? }
      ].freeze
      # Penalty weights N1 to N4 (§7.8.3.1), and the 1:1:3:1:1 pattern of a finder with four light modules beside it.
      PENALTY_RUN = 3
      PENALTY_BLOCK = 3
      PENALTY_FINDER_LIKE = 40
      PENALTY_BALANCE = 10
      EXPONENTS = Array.new(510).tap do |powers|
        value = 1
        255.times do |exponent|
          powers[exponent] = powers[exponent + 255] = value
          value = (value << 1) ^ ((value >> 7) * 0x11D)
        end
      end.freeze
      LOGARITHMS = Array.new(256).tap { |logarithms| 255.times { logarithms[EXPONENTS[_1]] = _1 } }.freeze
      # Generator polynomials by degree, each computed when first used: two threads computing one write the same.
      DIVISORS = {} # rubocop:disable Style/MutableConstant -- a cache
      LONG_RUN = /0{5,}|1{5,}/
      FINDER_LIKE = /(?=10111010000|00001011101)/

      attr_reader :version, :level, :mask, :size

      def initialize(text, level: :m)
        raise ArgumentError, "level is #{level.inspect}: accepted levels are #{LEVELS.map(&:inspect).join(", ")}" unless LEVELS.include?(level)

        @level = level
        bytes = text.to_s.encode(Encoding::UTF_8).b
        @version, bits = encode(bytes)
        @size = (@version * 4) + 17
        @modules = Array.new(@size) { Array.new(@size, false) }
        @function = Array.new(@size) { Array.new(@size, false) }
        draw_function_patterns
        place(interleaved(codewords(bits)))
        @mask = (0...MASKS.size).min_by { |mask| penalty_with(mask) }
        apply_mask(@mask)
        draw_format_bits(@mask)
      end

      def dark?(x, y)
        @modules[y][x]
      end

      def quiet_zone
        QUIET_ZONE
      end

      private

      # The bits of the one segment that holds the text, in the smallest version where they fit.
      def encode(bytes)
        mode = if bytes.match?(/\A\d*\z/n) then :numeric
        elsif bytes.each_char.all? { ALPHANUMERIC_VALUES.key?(_1) } then :alphanumeric
        else :byte
        end
        (1..40).each do |version|
          bits = segment_bits(bytes, mode, version)
          return [version, bits] if bits && bits.size <= data_codewords(version) * 8
        end
        raise ArgumentError, "#{bytes.bytesize} bytes do not fit a QR code at level #{@level.inspect}: lower the level or shorten the text"
      end

      def segment_bits(bytes, mode, version)
        indicator, count_widths = MODES.fetch(mode)
        count_width = count_widths[VERSION_RANGES.index { _1.cover?(version) }]
        count = (mode == :byte) ? bytes.bytesize : bytes.size
        return nil if count >= (1 << count_width)

        bits = []
        if mode == :byte && !bytes.ascii_only?
          append(bits, ECI_MODE, 4)
          append(bits, UTF8_ECI, 8)
        end
        append(bits, indicator, 4)
        append(bits, count, count_width)
        case mode
        when :numeric then bytes.scan(/\d{1,3}/n) { |digits| append(bits, digits.to_i, (digits.size * 3) + 1) }
        when :alphanumeric
          bytes.scan(/.{1,2}/mn) do |pair|
            values = pair.each_char.map { ALPHANUMERIC_VALUES.fetch(_1) }
            (values.size == 2) ? append(bits, (values[0] * 45) + values[1], 11) : append(bits, values[0], 6)
          end
        else bytes.each_byte { append(bits, _1, 8) }
        end
        bits
      end

      def append(bits, value, width)
        (width - 1).downto(0) { bits << value[_1] }
        bits
      end

      # Terminator, padding to a byte, then pad codewords up to the version's data capacity.
      def codewords(bits)
        capacity = data_codewords(@version) * 8
        bits.concat([0] * [4, capacity - bits.size].min)
        bits.concat([0] * (-bits.size % 8))
        data = bits.each_slice(8).map { |byte| byte.inject(0) { (_1 << 1) | _2 } }
        data << PAD_BYTES[(data.size - (capacity / 8)) % 2] while data.size < capacity / 8
        data
      end

      def raw_modules(version)
        result = (((16 * version) + 128) * version) + 64
        if version >= 2
          alignments = (version / 7) + 2
          result -= (((25 * alignments) - 10) * alignments) - 55
          result -= 36 if version >= 7
        end
        result
      end

      def data_codewords(version)
        (raw_modules(version) / 8) - (ECC_CODEWORDS_PER_BLOCK.fetch(@level)[version - 1] * BLOCKS.fetch(@level)[version - 1])
      end

      # Data split into blocks, each followed by its Reed-Solomon codewords, then read across the blocks.
      def interleaved(data)
        block_count = BLOCKS.fetch(@level)[@version - 1]
        ecc_length = ECC_CODEWORDS_PER_BLOCK.fetch(@level)[@version - 1]
        raw = raw_modules(@version) / 8
        short_blocks = block_count - (raw % block_count)
        short_length = raw / block_count
        divisor = reed_solomon_divisor(ecc_length)
        offset = 0
        blocks = Array.new(block_count) do |index|
          length = short_length - ecc_length + ((index < short_blocks) ? 0 : 1)
          block = data[offset, length]
          offset += length
          remainder = reed_solomon_remainder(block, divisor)
          block << nil if index < short_blocks
          block + remainder
        end
        (0...blocks.first.size).flat_map { |position| blocks.filter_map { _1[position] } }
      end

      def reed_solomon_divisor(degree)
        DIVISORS[degree] ||= divisor(degree)
      end

      def divisor(degree)
        result = Array.new(degree, 0)
        result[-1] = 1
        root = 1
        degree.times do
          degree.times do |index|
            result[index] = multiply(result[index], root)
            result[index] ^= result[index + 1] if index + 1 < degree
          end
          root = multiply(root, 0x02)
        end
        result
      end

      def reed_solomon_remainder(data, divisor)
        result = Array.new(divisor.size, 0)
        data.each do |byte|
          factor = byte ^ result.shift
          result << 0
          divisor.each_with_index { |coefficient, index| result[index] ^= multiply(coefficient, factor) }
        end
        result
      end

      # In GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1, through tables of powers of 2 and their logarithms.
      def multiply(x, y)
        (x.zero? || y.zero?) ? 0 : EXPONENTS[LOGARITHMS[x] + LOGARITHMS[y]]
      end

      def draw_function_patterns
        @size.times do |index|
          set_function(6, index, index.even?)
          set_function(index, 6, index.even?)
        end
        [[3, 3], [@size - 4, 3], [3, @size - 4]].each { |x, y| draw_finder(x, y) }
        positions = alignment_positions
        positions.each_with_index do |y, row|
          positions.each_with_index do |x, column|
            next if (row.zero? && column.zero?) || (row.zero? && column == positions.size - 1) || (row == positions.size - 1 && column.zero?)

            (-2..2).each { |dy| (-2..2).each { |dx| set_function(x + dx, y + dy, [dx.abs, dy.abs].max != 1) } }
          end
        end
        draw_format_bits(0)
        draw_version
      end

      def draw_finder(x, y)
        (-4..4).each do |dy|
          (-4..4).each do |dx|
            distance = [dx.abs, dy.abs].max
            set_function(x + dx, y + dy, distance != 2 && distance != 4) if (x + dx).between?(0, @size - 1) && (y + dy).between?(0, @size - 1)
          end
        end
      end

      def alignment_positions
        return [] if @version == 1

        count = (@version / 7) + 2
        step = (((@version * 8) + (count * 3) + 5) / ((count * 4) - 4)) * 2
        [6] + Array.new(count - 1) { |index| @size - 7 - (index * step) }.reverse
      end

      # Format information, in both its copies, and the dark module beside the lower left finder.
      def draw_format_bits(mask)
        data = (FORMAT_BITS.fetch(@level) << 3) | mask
        remainder = data
        10.times { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        bits = ((data << 10) | remainder) ^ 0x5412
        (0..5).each { set_function(8, _1, bits[_1] == 1) }
        set_function(8, 7, bits[6] == 1)
        set_function(8, 8, bits[7] == 1)
        set_function(7, 8, bits[8] == 1)
        (9..14).each { set_function(14 - _1, 8, bits[_1] == 1) }
        (0..7).each { set_function(@size - 1 - _1, 8, bits[_1] == 1) }
        (8..14).each { set_function(8, @size - 15 + _1, bits[_1] == 1) }
        set_function(8, @size - 8, true)
      end

      def draw_version
        return if @version < 7

        remainder = @version
        12.times { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        bits = (@version << 12) | remainder
        18.times do |index|
          dark = bits[index] == 1
          a = @size - 11 + (index % 3)
          b = index / 3
          set_function(a, b, dark)
          set_function(b, a, dark)
        end
      end

      def set_function(x, y, dark)
        @modules[y][x] = dark
        @function[y][x] = true
      end

      # Codewords in two-module columns, from the lower right corner, up then down, skipping the vertical timing line.
      def place(codewords)
        bit_count = codewords.size * 8
        index = 0
        right = @size - 1
        while right >= 1
          right = 5 if right == 6
          upward = ((right + 1) & 2).zero?
          @size.times do |vertical|
            y = upward ? @size - 1 - vertical : vertical
            [right, right - 1].each do |x|
              next if @function[y][x] || index >= bit_count

              @modules[y][x] = codewords[index >> 3][7 - (index & 7)] == 1
              index += 1
            end
          end
          right -= 2
        end
      end

      def apply_mask(mask)
        rule = MASKS.fetch(mask)
        @size.times do |y|
          row = @modules[y]
          function = @function[y]
          @size.times { |x| row[x] = !row[x] if !function[x] && rule.call(x, y) }
        end
      end

      def penalty_with(mask)
        apply_mask(mask)
        draw_format_bits(mask)
        penalty
      ensure
        apply_mask(mask)
      end

      # Rows and columns as strings of 0 and 1, which regular expressions scan for runs and finder-like patterns.
      def penalty
        rows = @modules.map { |row| row.map { _1 ? "1" : "0" }.join }
        columns = @modules.transpose.map! { |column| column.map { _1 ? "1" : "0" }.join }
        score = (rows + columns).sum do |line|
          line.scan(LONG_RUN).sum { PENALTY_RUN + _1.size - 5 } + (line.scan(FINDER_LIKE).size * PENALTY_FINDER_LIKE)
        end
        # 2x2 blocks of one colour: bits equal to their right neighbour in both rows, and between the rows.
        within = (1 << (@size - 1)) - 1
        rows.map { _1.to_i(2) }.each_cons(2) do |upper, lower|
          same = ~(upper ^ (upper >> 1)) & ~(lower ^ (lower >> 1)) & ~(upper ^ lower) & within
          score += same.to_s(2).count("1") * PENALTY_BLOCK
        end
        dark = rows.sum { _1.count("1") }
        total = @size * @size
        score + (((((dark * 20) - (total * 10)).abs + total - 1) / total) - 1) * PENALTY_BALANCE
      end
    end
  end
end
