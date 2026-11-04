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
        encode_keys(clusters) { |cluster| [cluster[1], cluster[0]] }
      end

      # The same for single characters, by code point: the common case, without building a cluster per character.
      def encode_codepoints(codepoints, glyph_by_code)
        encode_keys(codepoints) { |code| [code, glyph_by_code[code]] }
      end

      private

      # A character keeps its subset and code once given: later lookups are a single hash access.
      def encode_keys(items)
        parts = []
        items.each do |item|
          key, glyph = yield item
          index, code = @location_by_cluster[key] ||= code_for([glyph, key])
          if parts.empty? || parts.last[0] != index
            parts << [index, code.chr.b]
          else
            parts.last[1] << code
          end
        end
        parts
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
        subset_index = @subsets.rindex { |subset| subset.next_code && !subset.full? } || begin
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
