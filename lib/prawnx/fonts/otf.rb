# frozen_string_literal: true

module Prawn
  module Fonts
    # An OpenType font with CFF outlines, embedded as a Type0 font over a CIDFontType0: its character identifiers
    # are glyph indices, as a CFF program that is not CID-keyed requires (ISO 32000-1 §9.7.4.2).
    class OTF < TTF
      def encode_text(text, options = {})
        text = text.chomp
        runs =
          if @layout
            Array(shaped_runs(text, options[:kerning]))
          elsif options[:kerning]
            kern(text).map { it.is_a?(Numeric) ? it : glyph_string(it) }
          else
            [glyph_string(text.codepoints)]
          end
        runs = space_out_words(runs, options[:word_spacing], options[:font_size]) if options[:word_spacing].to_f.nonzero?
        [[0, (runs.size == 1) ? runs.first : runs]]
      end

      private

      def cluster_string(clusters)
        clusters.map do |glyph, codes|
          @code_by_glyph[glyph] ||= codes
          glyph
        end.pack("n*")
      end

      def embed(reference, _subset)
        @code_by_glyph ||= {}
        glyphs = [0, *@code_by_glyph.keys].uniq
        font_name = :"#{subset_tag_for(glyphs)}+#{basename.delete("\0")[0, 33]}"
        font_file = @document.ref!({Subtype: :CIDFontType0C}, PrawnX::TrueType::CffSubset.new(@ttf.table("CFF ")).bytes(glyphs))
        descriptor = @document.ref!(
          Type: :FontDescriptor, FontName: font_name, FontBBox: bbox, Flags: pdf_flags, StemV: stem_v, ItalicAngle: italic_angle,
          Ascent: @ascender, Descent: @descender, CapHeight: cap_height, XHeight: x_height, FontFile3: font_file
        )
        widths = glyphs.sort.flat_map { [it, [Integer(@ttf.advance_widths[it] * scale_factor)]] }
        descendant = @document.ref!(
          Type: :Font, Subtype: :CIDFontType0, BaseFont: font_name, FontDescriptor: descriptor, W: widths,
          CIDSystemInfo: {Registry: PDF::Core::LiteralString.new("Adobe"), Ordering: PDF::Core::LiteralString.new("Identity"), Supplement: 0}
        )
        reference.data.update(Subtype: :Type0, BaseFont: font_name, Encoding: :"Identity-H", DescendantFonts: [descendant],
          ToUnicode: @document.ref!({}, to_unicode_cmap(@code_by_glyph)))
      end
    end
  end
end
