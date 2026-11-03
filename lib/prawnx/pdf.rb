# frozen_string_literal: true

module PDF
  # PDF syntax: numbers, names, strings, arrays and dictionaries, as ISO 32000-1 §7.3 writes them.
  module Core
    Name = Data.define(:value)
    # A real number read from another file, written back exactly as it was read.
    Real = Data.define(:source) do
      def to_f = source.to_f
    end

    # Objects that build their dictionary when the document is written, once every reference they hold is known.
    module Serializable
    end
    LiteralString = Class.new(String)
    ByteString = Class.new(String)

    DELIMITER_OR_IRREGULAR_BYTES = ((0..32).to_a + [35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125] + (127..255).to_a).freeze
    LITERAL_STRING_ESCAPES = {"(" => "\\(", ")" => "\\)", "\\" => "\\\\", "\r" => "\\r"}.freeze
    REGULAR_NAME = %r{\A[!-~&&[^#%()<>\[\]{}/]]*\z}
    # Dictionary keys read from other files are symbols too: past a size no document of ours reaches, stop caching.
    NAME_CACHE_LIMIT = 10_000
    NAME_BY_SYMBOL = Hash.new do |cache, symbol|
      name = escape_name(symbol.to_s).freeze
      (cache.size < NAME_CACHE_LIMIT) ? cache[symbol] = name : name
    end

    module_function

    def escape_name(name)
      return "/#{name}" if name.match?(REGULAR_NAME)

      (+"/").concat(*name.b.each_byte.map { DELIMITER_OR_IRREGULAR_BYTES.include?(_1) ? format("#%02X", _1) : _1.chr })
    end

    # Five decimals, trailing zeros dropped but one: 1 is "1.0", 0.5 is "0.5", 1/3 is "0.33333".
    def real(number)
      digits = format("%.5f", number)
      last = digits.bytesize - 1
      last -= 1 while digits.getbyte(last) == 48 && digits.getbyte(last - 1) != 46
      digits.byteslice(0, last + 1)
    end

    def real_params(numbers)
      numbers.map { real(_1) }.join(" ")
    end

    # Integers as integers, other numbers to five decimals without a trailing ".0".
    def number(value)
      return value.to_s if value.is_a?(Integer)

      digits = real(value)
      digits.end_with?(".0") ? digits.delete_suffix(".0") : digits
    end

    def serialize(value, in_content_stream = false)
      case value
      when nil then "null"
      when true then "true"
      when false then "false"
      when Numeric then number(value)
      when Symbol then NAME_BY_SYMBOL[value]
      # Names read from other files are escaped every time: caching them would keep every font subset name forever.
      when Name then escape_name(value.value)
      when Real then value.source
      when LiteralString then "(#{value.gsub(/[\\\r()]/, LITERAL_STRING_ESCAPES)})"
      when ByteString then "<#{value.unpack1("H*")}>"
      when Time then "(#{value.strftime("D:%Y%m%d%H%M%S%z").chop.chop}'00')"
      when String then "<#{(in_content_stream ? value : utf16be(value)).unpack1("H*")}>"
      when Array then "[#{value.map { serialize(_1, in_content_stream) }.join(" ")}]"
      when Hash then "<<#{value.map { |key, entry| "#{serialize(key.to_sym)} #{serialize(entry, in_content_stream)}" }.join("\n")}>>"
      when Reference then value.to_s
      when Serializable then serialize(value.to_hash, in_content_stream)
      else raise Prawn::Errors::FailedObjectConversion, "This object cannot be serialized to PDF (#{value.inspect})"
      end
    end

    # PDF::Core's name for serialize, which code written for Prawn calls, prawn-svg among it.
    def pdf_object(object, in_content_stream = false)
      serialize(object, in_content_stream)
    end

    def utf16be(string)
      "\xFE\xFF".b + string.encode(::Encoding::UTF_16BE).b
    end
  end
end
