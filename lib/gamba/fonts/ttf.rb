# frozen_string_literal: true

require "digest/md5"

module Prawn
  module Fonts
    # A TrueType font, measured like Prawn measures it, embedded as one composite font per document: a Type0 font
    # with Identity-H encoding over a subset of the glyphs used.
    class TTF < Font
      class Error < StandardError
        DEFAULT_MESSAGE = "TTF font error"

        def initialize(message = DEFAULT_MESSAGE, font: nil)
          super((font && message == DEFAULT_MESSAGE) ? "TTF font error in font #{font}" : message)
        end
      end

      class NoUnicodeCMap < Error
        def initialize(message = "No unicode cmap found in font", font: nil)
          super(font ? "No unicode cmap found in font #{font}" : message)
        end
      end

      class NoPostscriptName < Error
        def initialize(message = "Can not detect a postscript name", font: nil)
          super(font ? "Can not detect a postscript name in font #{font}" : message)
        end
      end

      LINE_FEED = 10
      # FontDescriptor flags, ISO 32000-1 table 123.
      FIXED_PITCH_FLAG = 0x0001
      SERIF_FLAG = 0x0002
      SYMBOLIC_FLAG = 0x0004
      SCRIPT_FLAG = 0x0008
      ITALIC_FLAG = 0x0040
      # OS/2 sFamilyClass high bytes of serif and script families.
      SERIF_FAMILY_CLASSES = [1, 2, 3, 4, 5, 7].freeze
      SCRIPT_FAMILY_CLASS = 10
      TO_UNICODE_ENTRIES_PER_BLOCK = 100

      attr_reader :ttf

      def initialize(document, name, options = {})
        super
        @ttf = read_ttf_file
        raise NoUnicodeCMap.new(font: name) unless @ttf.unicode_cmap?
        @code_by_glyph = {}

        @subset = Gamba::TrueType::Subset.new(@ttf)
        @cid_by_cluster = {}
        @simple_subsets = Gamba::TrueType::SimpleSubsets.new(->(codes) { cmap[Array(codes).first] })
        @layout = Gamba::TrueType::OpenTypeLayout.new(@ttf, options[:features]) if options[:features]&.any?
        @width_by_code = {}
        @ascender = Integer(@ttf.ascent * scale_factor)
        @descender = Integer(@ttf.descent * scale_factor)
        @line_gap = Integer(@ttf.line_gap * scale_factor)
      end

      def unicode?
        true
      end

      # One pass over the characters, adding each kerning offset before the character it precedes: the same
      # sums, in the same order, as measuring the runs of #kern.
      def compute_width_of(string, options = {})
        return shaped_width_of(string, options) if @layout

        scale = (options[:size] || size) / 1000.0
        kerning = options[:kerning]
        width = 0
        previous_glyph = nil
        string.each_codepoint do |code|
          glyph = cmap[code]
          if kerning && previous_glyph && (offset = @ttf.kerning_offset(previous_glyph, glyph))
            width -= -(offset * scale_factor)
          end
          width += character_width_by_code(code)
          previous_glyph = glyph
        end
        width * scale
      end

      def bbox
        @bbox ||= @ttf.header.to_h.values_at(:x_min, :y_min, :x_max, :y_max).map! { Integer(_1 * scale_factor) }
      end

      def has_kerning_data?
        @ttf.kerning?
      end

      def encode_text(text, options = {})
        text = text.chomp
        unless @layout
          return options[:kerning] ? encode_kerned_codepoints(text.codepoints) : @simple_subsets.encode_codepoints(text.codepoints, cmap)
        end

        encode_shaped(text.codepoints, options[:kerning])
      end

      def basename
        @basename ||= @ttf.postscript_name
      end

      def stem_v
        0
      end

      # The post table's Fixed italic angle, read the way Prawn reads it.
      def italic_angle
        @italic_angle ||= begin
          raw = @ttf.italic_angle_fixed
          if raw
            high = raw >> 16
            low = raw & 0xFF
            high = -((high ^ 0xFFFF) + 1) if high & 0x8000 != 0
            Float("#{high}.#{low}")
          else
            0
          end
        end
      end

      def cap_height
        @cap_height ||= @ttf.os2[:cap_height].to_i.then { |cap_height| cap_height.zero? ? @ascender : cap_height }
      end

      def x_height
        @ttf.os2[:x_height] || 0
      end

      def family_class
        @family_class ||= @ttf.os2[:family_class].to_i >> 8
      end

      def serif?
        SERIF_FAMILY_CLASSES.include?(family_class)
      end

      def script?
        family_class == SCRIPT_FAMILY_CLASS
      end

      def pdf_flags
        flags = SYMBOLIC_FLAG
        flags |= FIXED_PITCH_FLAG if @ttf.fixed_pitch?
        flags |= SERIF_FLAG if serif?
        flags |= SCRIPT_FLAG if script?
        flags |= ITALIC_FLAG if italic_angle != 0
        flags
      end

      def normalize_encoding(text)
        text.encode(::Encoding::UTF_8)
      rescue
        raise Errors::IncompatibleStringEncoding,
          "Encoding #{text.encoding} can not be transparently converted to UTF-8. " \
          "Please ensure the encoding of the string you are attempting to use is set correctly"
      end

      def to_utf8(text)
        text.encode(::Encoding::UTF_8)
      end

      def measured_string(string)
        (string.encoding == ::Encoding::UTF_8) ? string : normalize_encoding(string)
      end

      def glyph_present?(character)
        cmap[character.codepoints.first].positive?
      end

      # Glyphs, which character spacing applies to: fewer than characters once ligatures join some.
      def character_count(string)
        return string.length unless @layout

        count = 0
        @layout.each_glyph(string.codepoints) { count += 1 }
        count
      end

      private

      def read_ttf_file
        Gamba::TrueType::File.open(@name)
      end

      def cmap
        @ttf.glyph_by_code
      end

      def scale_factor
        @scale_factor ||= 1000.0 / @ttf.header.units_per_em
      end

      def character_width_by_code(code)
        return 0.0 if code == LINE_FEED

        @width_by_code[code] ||= Integer(@ttf.advance_widths[cmap[code]] * scale_factor)
      end

      # Runs of code points, separated by the kerning offset between two glyphs, in thousandths of the font size.
      def kern(string)
        runs = []
        string.each_codepoint do |code|
          if runs.empty?
            runs << [code]
          elsif (offset = @ttf.kerning_offset(cmap[runs.last.last], cmap[code]))
            runs << -(offset * scale_factor) << [code]
          else
            runs.last << code
          end
        end
        runs
      end

      def glyph_string(codes)
        cluster_string(codes.map { |code| [cmap[code], code] })
      end

      # One character identifier per cluster of characters, in order of first use (0 stays .notdef): characters
      # sharing a glyph keep their own Unicode value for text extraction, a ligature all of its characters.
      def cluster_string(clusters)
        clusters.map do |glyph, codes|
          @cid_by_cluster[codes] ||= begin
            (@glyph_by_cid ||= [0]) << glyph
            @glyph_by_cid.size - 1
          end
        end.pack("n*")
      end

      # PDF word spacing (Tw) only reaches byte 32 of single-byte encodings (ISO 32000-1 §9.3.3): with two-byte
      # codes, each space gets the same shift as a TJ offset instead.
      def space_out_words(runs, word_spacing, font_size)
        space = glyph_string([32])
        # From the spacing as Tw would write it, rounded to five decimals, so spaces land where Prawn's do.
        offset = -(Float(PDF::Core.real(word_spacing)) * 1000.0 / font_size)
        runs.flat_map do |run|
          next [run] unless run.is_a?(String)

          run.b.scan(/../mn).slice_after(space).flat_map { |codes| (codes.last == space) ? [codes.join, offset] : [codes.join] }
        end
      end

      def shaped_width_of(string, options)
        width = 0
        previous_glyph = nil
        codes = string.codepoints
        @layout.each_glyph(codes) do |glyph, index, length|
          if options[:kerning] && previous_glyph && (offset = kerning_between(previous_glyph, glyph))
            width += offset * scale_factor
          end
          width += (length == 1 && codes[index] == LINE_FEED) ? 0.0 : Integer(@ttf.advance_widths[glyph] * scale_factor)
          previous_glyph = glyph
        end
        width * ((options[:size] || size) / 1000.0)
      end

      def shaped_runs(text, kerning)
        clusters = @layout.shape(text.codepoints)
        return cluster_string(clusters) unless kerning

        runs = []
        run = []
        clusters.each do |cluster|
          if run.any? && (offset = kerning_between(run.last[0], cluster[0]))
            runs << cluster_string(run) << -(offset * scale_factor)
            run = []
          end
          run << cluster
        end
        runs << cluster_string(run)
      end

      def kerning_between(left, right)
        return @ttf.kerning_offset(left, right) unless @layout

        @layout.kerning(left, right) || (@ttf.kerning_offset(left, right) unless options[:features].include?(:kern))
      end

      def encode_kerned_codepoints(codepoints)
        encoded = []
        run_start = 0
        previous_glyph = nil
        codepoints.each_with_index do |code, index|
          glyph = cmap[code]
          if previous_glyph && (offset = @ttf.kerning_offset(previous_glyph, glyph))
            merge_encoded_parts(encoded, @simple_subsets.encode_codepoints(codepoints[run_start...index], cmap))
            encoded.last[1] = Array(encoded.last[1]) << -(offset * scale_factor)
            run_start = index
          end
          previous_glyph = glyph
        end
        merge_encoded_parts(encoded, @simple_subsets.encode_codepoints(codepoints[run_start..], cmap))
      end

      # Runs of one subset merge into the previous part when it is of the same subset, as in Prawn's TJ arrays.
      # Each glyph's code straight into the parts of its run, with no cluster built for it: text is drawn glyph by
      # glyph, and most glyphs stand for one character.
      def encode_shaped(codes, kerning)
        encoded = []
        run = []
        previous_glyph = nil
        @layout.each_glyph(codes) do |glyph, index, length|
          if kerning && previous_glyph && (offset = kerning_between(previous_glyph, glyph))
            merge_encoded_parts(encoded, run)
            encoded.last[1] = Array(encoded.last[1]) << -(offset * scale_factor)
            run = []
          end
          @simple_subsets.append_cluster(run, glyph, Gamba::TrueType::OpenTypeLayout.cluster_codes(codes, index, length))
          previous_glyph = glyph
        end
        merge_encoded_parts(encoded, run)
      end

      def merge_encoded_parts(encoded, parts)
        return encoded if parts.empty?

        if encoded.any? && parts.first[0] == encoded.last[0]
          encoded.last[1] << parts.shift[1]
        end
        encoded.concat(parts)
      end

      def register(subset)
        reference = @document.ref!(Type: :Font, BaseFont: basename.delete("\0").to_sym)
        @document.before_render { embed(reference, subset) }
        reference
      end

      # A simple TrueType font of single-byte codes, as Prawn embeds them: a font program with a Mac Roman cmap
      # from those codes to its glyphs, widths per code, and a ToUnicode map.
      def embed(reference, subset_index)
        subset = @simple_subsets[subset_index]
        program = Gamba::TrueType::Subset.new(@ttf)
        # Glyphs numbered as TTFunk numbers them, by character code then components: TrueType hinting can depend
        # on glyph indices, and a different order rasterizes differently in MuPDF.
        subset.glyph_by_code.sort.each { |_code, glyph| program.glyph_for(glyph) unless glyph.zero? }
        program.add_components(subset.glyph_by_code.values.uniq.sort!)
        glyph_by_code = subset.glyph_by_code.transform_values { program.glyph_for(_1) }
        mac_roman_cmap = [0, 1, 1, 0, 12, 0, 262, 0].pack("n4 N n3") + Array.new(256) { |code| glyph_by_code[code] || 0 }.pack("C*")
        font_name = :"#{subset_tag_for(program.original_glyphs)}+#{basename.delete("\0")[0, 33]}"
        font_bytes = program.bytes("cmap" => mac_roman_cmap)
        font_file = @document.ref!({Length1: font_bytes.bytesize}, font_bytes)
        descriptor = @document.ref!(
          Type: :FontDescriptor, FontName: font_name, FontBBox: bbox, Flags: pdf_flags, StemV: stem_v, ItalicAngle: italic_angle,
          Ascent: @ascender, Descent: @descender, CapHeight: cap_height, XHeight: x_height, FontFile2: font_file
        )
        first_code, last_code = subset.glyph_by_code.keys.minmax
        widths = (first_code..last_code).map do |code|
          glyph = subset.glyph_by_code[code]
          glyph ? Integer(@ttf.advance_widths[glyph] * scale_factor) : 0
        end
        codes_by_code = subset.code_by_cluster.each_with_object({}) { |(codes, code), map| map[code] ||= Array(codes) }
        reference.data.update(Subtype: :TrueType, BaseFont: font_name, FontDescriptor: descriptor, FirstChar: first_code, LastChar: last_code,
          Widths: @document.ref!(widths), ToUnicode: @document.ref!({}, to_unicode_cmap(codes_by_code, code_bytes: 1)))
      end

      # Six capital letters derived from the glyphs kept, as ISO 32000-1 §9.6.4 asks of a subset's name.
      def subset_tag
        subset_tag_for(@subset.original_glyphs)
      end

      def subset_tag_for(glyphs)
        Digest::MD5.digest(glyphs.pack("n*")).bytes.first(6).map! { |byte| ("A".ord + (byte % 26)).chr }.join
      end

      def to_unicode_cmap(codes_by_cid, code_bytes: 2)
        entries = codes_by_cid.map { |cid, codes| format("<%0*X> <%s>", code_bytes * 2, cid, Array(codes).pack("U*").encode(::Encoding::UTF_16BE).unpack1("H*").upcase) }
        blocks = entries.each_slice(TO_UNICODE_ENTRIES_PER_BLOCK).map { |block_entries| "#{block_entries.size} beginbfchar\n#{block_entries.join("\n")}\nendbfchar" }
        <<~CMAP
          /CIDInit /ProcSet findresource begin
          12 dict begin
          begincmap
          /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
          /CMapName /Adobe-Identity-UCS def
          /CMapType 2 def
          1 begincodespacerange
          #{(code_bytes == 1) ? "<00> <FF>" : "<0000> <FFFF>"}
          endcodespacerange
          #{blocks.join("\n")}
          endcmap
          CMapName currentdict /CMap defineresource pop
          end
          end
        CMAP
      end
    end

    class TTC < TTF
      def self.font_names(file)
        collection = ::File.binread(file)
        Array.new(collection.unpack1("@8 N")) { |index| Gamba::TrueType::File.new(collection, index:).font_name }
      end

      private

      def read_ttf_file
        index = @options[:font].is_a?(Numeric) ? @options[:font] : self.class.font_names(@name).index(@options[:font]) || 0
        Gamba::TrueType::File.open(@name, index:)
      end
    end

    class DFont < TTF
      private

      def read_ttf_file
        Gamba::TrueType::File.open(@name, index: @options[:font] || 0, resource: true)
      end
    end
  end

  class Font
    AFM = Fonts::AFM
    TTF = Fonts::TTF
    TTC = Fonts::TTC
    DFont = Fonts::DFont
  end
end
