# frozen_string_literal: true

module PrawnX
  module TrueType
    # Characters of a TrueType font split into simple fonts of single-byte codes, laid out as Prawn lays them
    # (through TTFunk) so every reader renders them the same way: the first subset codes characters in Mac Roman,
    # keeping space at 32 for word spacing; the next ones take 223 characters each, from code 33.
    class SimpleSubsets
      Subset = Struct.new(:code_by_cluster, :glyph_by_code, :next_code) do
        def full?
          next_code > 255
        end
      end

      SPACE = 32
      FIRST_FREE_CODE = 33

      def initialize(glyph_for_cluster)
        @glyph_for_cluster = glyph_for_cluster
        @location_by_cluster = {}
        @subsets = [Subset.new({SPACE => SPACE}, {SPACE => glyph_for_cluster.call([SPACE])}, nil)]
      end

      def size
        @subsets.size
      end

      def [](index)
        @subsets[index]
      end

      # [[subset index, bytes], …] for clusters of characters, each cluster [glyph, codes].
      def encode(clusters)
        parts = []
        clusters.each do |glyph, codes|
          append(parts, *(@location_by_cluster[codes] ||= code_for([glyph, codes])))
        end
        parts
      end

      # The same for single characters, by code point: the common case, where a character already given its code
      # costs a single hash access, and its glyph is only looked up the first time.
      def encode_codepoints(codepoints, glyph_by_code)
        parts = []
        codepoints.each do |codepoint|
          index, code = @location_by_cluster[codepoint] ||= code_for([glyph_by_code[codepoint], codepoint])
          append(parts, index, code)
        end
        parts
      end

      private

      # Consecutive characters of one subset share a part, as in Prawn's TJ arrays.
      def append(parts, index, code)
        last = parts.last
        if last.nil? || last[0] != index
          parts << [index, code.chr(::Encoding::BINARY)]
        else
          last[1] << code
        end
      end

      def code_for(cluster)
        glyph, codes = cluster
        key = codes
        mac_roman = mac_roman_code(codes)
        if mac_roman
          @subsets[0].code_by_cluster[key] ||= mac_roman.tap { @subsets[0].glyph_by_code[mac_roman] = glyph }
          return [0, mac_roman]
        end

        @subsets.each_with_index.drop(1).each do |subset, index|
          code = subset.code_by_cluster[key]
          return [index, code] if code
        end
        subset_index = @subsets.rindex { _1.next_code && !_1.full? } || begin
          @subsets << Subset.new({[SPACE] => SPACE, SPACE => SPACE}, {SPACE => @glyph_for_cluster.call([SPACE])}, FIRST_FREE_CODE)
          @subsets.size - 1
        end
        subset = @subsets[subset_index]
        code = subset.next_code
        subset.code_by_cluster[key] = code
        subset.glyph_by_code[code] = glyph
        subset.next_code += 1
        [subset_index, code]
      end

      def mac_roman_code(codes)
        codes = Array(codes)
        return unless codes.size == 1

        [codes.first].pack("U").encode(::Encoding::MacRoman).getbyte(0)
      rescue ::Encoding::UndefinedConversionError
        nil
      end
    end
  end
end
