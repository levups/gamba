# frozen_string_literal: true

module Gamba
  module Barcodes
    # A linear barcode as the widths of its bars and spaces, in modules, from the first bar: Code 128 (sets A, B
    # and C chosen as the text goes), EAN-13, EAN-8, Code 39 and ITF-14. Check digits are added when left out,
    # and checked when given.
    class Linear
      TYPES = %i[code128 ean13 ean8 code39 itf14].freeze
      # Light margins scanners need, in modules, before and after the bars.
      QUIET_ZONES = {code128: [10, 10], ean13: [11, 7], ean8: [7, 7], code39: [10, 10], itf14: [10, 10]}.freeze
      WIDE = 3

      CODE128_PATTERNS = %w[
        212222 222122 222221 121223 121322 131222 122213 122312 132212 221213 221312 231212 112232 122132 122231 113222
        123122 123221 223211 221132 221231 213212 223112 312131 311222 321122 321221 312212 322112 322211 212123 212321
        232121 111323 131123 131321 112313 132113 132311 211313 231113 231311 112133 112331 132131 113123 113321 133121
        313121 211331 231131 213113 213311 213131 311123 311321 331121 312113 312311 332111 314111 221411 431111 111224
        111422 121124 121421 141122 141221 112214 112412 122114 122411 142112 142211 241211 221114 413111 241112 134111
        111242 121142 121241 114212 124112 124211 411212 421112 421211 212141 214121 412121 111143 111341 131141 114113
        114311 411113 411311 113141 114131 311141 411131 211412 211214 211232 2331112
      ].map { |pattern| pattern.each_char.map(&:to_i).freeze }.freeze
      CODE128_START = {a: 103, b: 104, c: 105}.freeze
      CODE128_SWITCH = {a: 101, b: 100, c: 99}.freeze
      CODE128_STOP = 106
      # Digits worth a switch to set C: fewer cost more than they save.
      CODE128_DIGITS_FOR_C = 4

      EAN_L = %w[0001101 0011001 0010011 0111101 0100011 0110001 0101111 0111011 0110111 0001011].freeze
      EAN_G = %w[0100111 0110011 0011011 0100001 0011101 0111001 0000101 0010001 0001001 0010111].freeze
      EAN_R = %w[1110010 1100110 1101100 1000010 1011100 1001110 1010000 1000100 1001000 1110100].freeze
      # Which left digits of an EAN-13 take the G patterns, by its first digit, which no pattern encodes.
      EAN13_PARITY = %w[LLLLLL LLGLGG LLGGLG LLGGGL LGLLGG LGGLLG LGGGLL LGLGLG LGLGGL LGGLGL].freeze

      CODE39 = {
        "0" => "nnnwwnwnn", "1" => "wnnwnnnnw", "2" => "nnwwnnnnw", "3" => "wnwwnnnnn", "4" => "nnnwwnnnw",
        "5" => "wnnwwnnnn", "6" => "nnwwwnnnn", "7" => "nnnwnnwnw", "8" => "wnnwnnwnn", "9" => "nnwwnnwnn",
        "A" => "wnnnnwnnw", "B" => "nnwnnwnnw", "C" => "wnwnnwnnn", "D" => "nnnnwwnnw", "E" => "wnnnwwnnn",
        "F" => "nnwnwwnnn", "G" => "nnnnnwwnw", "H" => "wnnnnwwnn", "I" => "nnwnnwwnn", "J" => "nnnnwwwnn",
        "K" => "wnnnnnnww", "L" => "nnwnnnnww", "M" => "wnwnnnnwn", "N" => "nnnnwnnww", "O" => "wnnnwnnwn",
        "P" => "nnwnwnnwn", "Q" => "nnnnnnwww", "R" => "wnnnnnwwn", "S" => "nnwnnnwwn", "T" => "nnnnwnwwn",
        "U" => "wwnnnnnnw", "V" => "nwwnnnnnw", "W" => "wwwnnnnnn", "X" => "nwnnwnnnw", "Y" => "wwnnwnnnn",
        "Z" => "nwwnwnnnn", "-" => "nwnnnnwnw", "." => "wwnnnnwnn", " " => "nwwnnnwnn", "$" => "nwnwnwnnn",
        "/" => "nwnwnnnwn", "+" => "nwnnnwnwn", "%" => "nnnwnwnwn", "*" => "nwnnwnwnn"
      }.transform_values { |pattern| pattern.each_char.map { (_1 == "w") ? WIDE : 1 }.freeze }.freeze

      ITF = %w[nnwwn wnnnw nwnnw wwnnn nnwnw wnwnn nwwnn nnnww wnnwn nwnwn].map do |pattern|
        pattern.each_char.map { (_1 == "w") ? WIDE : 1 }.freeze
      end.freeze
      ITF_START = [1, 1, 1, 1].freeze
      ITF_STOP = [WIDE, 1, 1].freeze

      attr_reader :type, :widths, :text

      def initialize(data, type:)
        raise ArgumentError, "type is #{type.inspect}: accepted types are #{TYPES.map(&:inspect).join(", ")}" unless TYPES.include?(type)

        @type = type
        @text = data.to_s
        @widths = send(type)
      end

      def quiet_zones
        QUIET_ZONES.fetch(@type)
      end

      # Modules from the first bar to the end of the last.
      def length
        @widths.sum
      end

      private

      def code128
        raise ArgumentError, "Code 128 encodes ASCII: #{@text.inspect} is not" unless @text.ascii_only?
        raise ArgumentError, "Code 128 needs at least one character" if @text.empty?

        values = code128_values(@text)
        checksum = values.each_with_index.sum { |value, position| value * [position, 1].max } % 103
        (values + [checksum, CODE128_STOP]).flat_map { CODE128_PATTERNS[_1] }
      end

      # Set C for runs of digits long enough to pay for the switch, A for control characters, B otherwise.
      def code128_values(text)
        values = []
        set = nil
        position = 0
        while position < text.size
          digits = text[position..][/\A\d+/].to_s.size
          if digits >= CODE128_DIGITS_FOR_C || (digits >= 2 && digits == text.size - position && (set.nil? || set == :c))
            if digits.odd?
              set = code128_switch(values, set, code128_set_for(text[position]))
              values << code128_value(text[position], set)
              position += 1
              digits -= 1
            end
            set = code128_switch(values, set, :c)
            text[position, digits].scan(/\d\d/) { values << _1.to_i }
            position += digits
          else
            character = text[position]
            set = code128_switch(values, set, code128_set_for(character)) unless set && set != :c && code128_value(character, set)
            values << code128_value(character, set)
            position += 1
          end
        end
        values
      end

      def code128_set_for(character)
        (character.ord < 32) ? :a : :b
      end

      def code128_switch(values, current, wanted)
        return current if current == wanted

        values << (current.nil? ? CODE128_START : CODE128_SWITCH).fetch(wanted)
        wanted
      end

      def code128_value(character, set)
        code = character.ord
        if set == :a
          return code + 64 if code < 32

          code - 32 if code < 96
        elsif set == :b
          code - 32 if code >= 32
        end
      end

      def ean13
        digits = check_digits(13)
        parity = EAN13_PARITY[digits.first]
        left = digits[1, 6].each_with_index.map { |digit, index| ((parity[index] == "G") ? EAN_G : EAN_L)[digit] }
        modules("101" + left.join + "01010" + digits[7, 6].map { EAN_R[_1] }.join + "101")
      end

      def ean8
        digits = check_digits(8)
        modules("101" + digits[0, 4].map { EAN_L[_1] }.join + "01010" + digits[4, 4].map { EAN_R[_1] }.join + "101")
      end

      def code39
        text = @text = @text.upcase
        unknown = text.each_char.reject { CODE39.key?(_1) && _1 != "*" }
        raise ArgumentError, "Code 39 encodes 0-9, A-Z, space and - . $ / + %: #{unknown.uniq.join.inspect} is not among them" unless unknown.empty?

        "*#{text}*".each_char.flat_map { CODE39.fetch(_1) + [1] }[0...-1]
      end

      def itf14
        digits = check_digits(14)
        pairs = digits.each_slice(2).flat_map { |bars, spaces| ITF[bars].zip(ITF[spaces]).flatten! }
        ITF_START + pairs + ITF_STOP
      end

      # The digits of a GTIN-like number of `count` digits, its check digit added when it lacks one: weights 3 and 1
      # from the right (GS1 General Specifications §7.9).
      def check_digits(count)
        raise ArgumentError, "#{@type.to_s.upcase} encodes #{count - 1} digits and a check digit: #{@text.inspect} is not that" unless @text.match?(/\A\d{#{count - 1},#{count}}\z/)

        digits = @text.each_char.map(&:to_i)
        check = check_digit(digits.first(count - 1))
        raise ArgumentError, "#{@text} ends in #{digits.last}, but its check digit is #{check}" if digits.size == count && digits.last != check

        @text = (digits.first(count - 1) + [check]).join
        digits.first(count - 1) + [check]
      end

      def check_digit(digits)
        sum = digits.reverse.each_with_index.sum { |digit, index| index.even? ? digit * 3 : digit }
        (10 - (sum % 10)) % 10
      end

      # "1011…" as widths of runs, from the first bar.
      def modules(bits)
        bits.scan(/1+|0+/).map(&:size)
      end
    end
  end
end
