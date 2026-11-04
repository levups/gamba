# frozen_string_literal: true

module PrawnX
  module TrueType
    class Error < StandardError
    end

    # The tables of a TrueType font that layout and embedding need, read once from its bytes: from a .ttf, one
    # font of a .ttc collection, or one sfnt resource of a Mac .dfont.
    class File
      TRUE_TYPE_VERSIONS = ["\x00\x01\x00\x00".b, "true".b].freeze
      COLLECTION_TAG = "ttcf".b
      UNICODE_CMAP_FORMATS = [4, 6, 10, 12].freeze
      REQUIRED_TABLES = %w[head hhea maxp hmtx cmap].freeze
      # The fewest bytes a table may hold (head and hhea: their fixed sizes, OS/2: Apple's 68-byte version 0): shorter,
      # the fields read at fixed offsets would read as nil or past its end.
      MINIMUM_TABLE_SIZES = {"head" => 54, "hhea" => 36, "maxp" => 6, "OS/2" => 68, "post" => 16}.freeze
      # Reading past the data a malformed font declares raises these: they become a TrueType::Error.
      MALFORMED_FONT_ERRORS = [ArgumentError, TypeError, RangeError, NoMethodError, FloatDomainError].freeze
      MAXIMUM_CODE_POINT = 0x10FFFF

      Header = Data.define(:units_per_em, :x_min, :y_min, :x_max, :y_max, :index_to_location_format)

      FILES_BY_KEY = {}
      FILES_LOCK = Mutex.new

      # Parsed fonts are shared by every document of the process, until their file changes.
      def self.open(path, index: 0, resource: false)
        key = [::File.expand_path(path), index, resource, ::File.mtime(path)]
        FILES_LOCK.synchronize { FILES_BY_KEY[key] ||= new(::File.binread(path), index:, resource:) }
      end

      attr_reader :bytes, :offset

      def initialize(bytes, index: 0, resource: false)
        @bytes = bytes.b.freeze
        @offset = resource ? resource_offset(index) : 0
        @offset = collection_offset(index) if @bytes.byteslice(@offset, 4) == COLLECTION_TAG
        @location_by_tag = read_table_directory
        validate!
      rescue *MALFORMED_FONT_ERRORS => exception
        raise Error, "Malformed font: #{exception.message}"
      end

      def table?(tag)
        @location_by_tag.key?(tag)
      end

      def table(tag)
        offset, length = @location_by_tag[tag]
        @bytes.byteslice(offset, length) if offset
      end

      def outline_format
        if table?("glyf") then :true_type
        elsif table?("CFF ") then :open_type
        else :unknown
        end
      end

      def header
        @header ||= begin
          units_per_em, x_min, y_min, x_max, y_max = table("head").unpack("@18 n x16 s>4")
          Header.new(units_per_em:, x_min:, y_min:, x_max:, y_max:, index_to_location_format: table("head").unpack1("@50 s>"))
        end
      end

      def glyph_count
        @glyph_count ||= table("maxp").unpack1("@4 n")
      end

      # The OS/2 typographic metric when present and not zero, the hhea one otherwise.
      def ascent
        @ascent ||= nonzero_os2(:ascent) || horizontal_header[0]
      end

      def descent
        @descent ||= nonzero_os2(:descent) || horizontal_header[1]
      end

      def line_gap
        @line_gap ||= nonzero_os2(:line_gap) || horizontal_header[2]
      end

      def os2
        @os2 ||= begin
          os2 = table("OS/2")
          if os2
            version = os2.unpack1("n")
            family_class = os2.unpack1("@30 s>")
            ascent, descent, line_gap = os2.unpack("@68 s>3")
            x_height, cap_height = os2.unpack("@86 s>2") if version >= 2 && os2.bytesize >= 90
            {family_class:, ascent:, descent:, line_gap:, x_height:, cap_height:}
          else
            {}
          end
        end
      end

      def italic_angle_fixed
        table("post")&.unpack1("@4 N")
      end

      def fixed_pitch?
        table("post")&.unpack1("@12 N").to_i != 0
      end

      def postscript_name
        @postscript_name ||= name_string(6) || name_string(1) || "unnamed"
      end

      def font_name
        name_string(4)
      end

      def family_name
        name_string(1)
      end

      # Underline position and thickness from the post table, in font units.
      def underline_metrics
        table("post").unpack("@8 s>2")
      end

      def strikeout_position
        table("OS/2").unpack1("@28 s>")
      end

      # The lowest and highest points of a glyph's outline, in font units, from its glyf header.
      def glyph_vertical_bounds(glyph)
        data = glyph_data(glyph)
        return [0, 0] if data.bytesize < 10

        data.unpack("@4 s> x2 s>")
      end

      # Advance widths in font units, one per glyph: glyphs past the last metric share its advance.
      def advance_widths
        @advance_widths ||= begin
          metric_count = horizontal_header[3]
          raise Error, "Malformed font: no horizontal metrics" unless metric_count.between?(1, table("hmtx").bytesize / 4)
          widths = table("hmtx").unpack("n*").each_slice(2).first(metric_count).map!(&:first)
          widths + ([widths.last] * (glyph_count - metric_count))
        end
      end

      def glyph_by_code
        @glyph_by_code ||= read_unicode_cmap || raise(Error, "No unicode cmap found in font")
      end

      def unicode_cmap?
        !read_unicode_cmap.nil?
      end

      def kerning?
        !kerning_by_glyph_key.empty?
      end

      # Kerning between two glyphs, in font units, or nil.
      def kerning_offset(left, right)
        kerning_by_glyph_key[(left << 16) | right]
      end

      def glyph_data(glyph)
        offsets = glyph_offsets
        start = offsets[glyph]
        table_bytes = glyf_table
        table_bytes.byteslice(start, offsets[glyph + 1] - start) || "".b
      end

      private

      # Fonts may come from users: everything layout reads later is read and checked once, here.
      def validate!
        missing = REQUIRED_TABLES.reject { table?(_1) }
        raise Error, "Malformed font: no #{missing.join(", ")} table" unless missing.empty?
        raise Error, "Malformed font: no outlines" if outline_format == :unknown

        @location_by_tag.each do |tag, (offset, length)|
          raise Error, "Malformed font: the #{tag} table lies outside the file" if offset + length > @bytes.bytesize
          raise Error, "Malformed font: its #{tag} table is too short" if length < MINIMUM_TABLE_SIZES.fetch(tag, 0)
        end
        raise Error, "Malformed font: no glyphs" unless glyph_count.positive?
        # Glyph units scale to text space by 1000 / unitsPerEm: zero would make every metric infinite.
        raise Error, "Malformed font: its unitsPerEm is zero" if header.units_per_em.zero?

        advance_widths
        read_unicode_cmap
        kerning_by_glyph_key
        validate_glyph_offsets! if outline_format == :true_type
      end

      def validate_glyph_offsets!
        offsets = glyph_offsets
        glyf_size = glyf_table.bytesize
        valid = offsets.size == glyph_count + 1 && offsets.each_cons(2).all? { |start, finish| start <= finish } && offsets.last <= glyf_size
        raise Error, "Malformed font: its glyph locations do not fit its glyph table" unless valid
      end

      def horizontal_header
        @horizontal_header ||= begin
          ascent, descent, line_gap = table("hhea").unpack("@4 s>3")
          [ascent, descent, line_gap, table("hhea").unpack1("@34 n")]
        end
      end

      def nonzero_os2(metric)
        value = os2[metric]
        value if value&.nonzero?
      end

      def glyf_table
        @glyf_table ||= table("glyf")
      end

      def glyph_offsets
        @glyph_offsets ||=
          if header.index_to_location_format.zero?
            table("loca").unpack("n#{glyph_count + 1}").map { _1 * 2 }
          else
            table("loca").unpack("N#{glyph_count + 1}")
          end
      end

      # The first kerning subtable's values, keyed by `left << 16 | right` like its records.
      def kerning_by_glyph_key
        @kerning_by_glyph_key ||= begin
          kern = table("kern")
          subtable = nil
          if kern
            version = kern.unpack1("n")
            if version == 1
              length, coverage = kern.unpack("@8 N n")
              subtable = kern.byteslice(16, length - 8) if (coverage & 0xFF).zero?
            elsif kern.unpack1("@2 n").positive?
              coverage = kern.unpack1("@8 n")
              subtable = kern.byteslice(10..) if (coverage >> 8).zero?
            end
          end
          subtable ? format0_kerning_by_glyph_key(subtable) : {}
        end
      end

      # A format 0 record is a uint32 glyph pair key then an int16 value: `N s>` reads both as they are stored.
      def format0_kerning_by_glyph_key(subtable)
        pair_count = [subtable.unpack1("n"), (subtable.bytesize - 8) / 6].min
        Hash[*subtable.unpack("@8 #{"N s>" * pair_count}")]
      end

      def read_table_directory
        version, table_count = @bytes.unpack("@#{@offset} a4 n")
        raise Error, "Not a TrueType font" unless TRUE_TYPE_VERSIONS.include?(version) || version == "OTTO"

        Array.new(table_count) do |index|
          tag, _checksum, offset, length = @bytes.unpack("@#{@offset + 12 + (index * 16)} a4 N3")
          [tag, [offset + (@offset_base || 0), length]]
        end.to_h
      end

      def collection_offset(index)
        font_count = @bytes.unpack1("@8 N")
        raise Error, "Font index #{index} out of a collection of #{font_count}" if index >= font_count

        @bytes.unpack1("@#{12 + (index * 4)} N")
      end

      # A Mac resource fork: table offsets in its sfnt resources count from the resource's own start.
      def resource_offset(index)
        data_offset, map_offset = @bytes.unpack("N2")
        type_list_offset, name_list_offset = @bytes.unpack("@#{map_offset + 24} n2")
        type_list = map_offset + type_list_offset
        type_count = @bytes.unpack1("@#{type_list} n") + 1
        type_count.times do |type_index|
          type, count, reference_list_offset = @bytes.unpack("@#{type_list + 2 + (type_index * 8)} a4 n2")
          next unless type == "sfnt"

          references = Array.new(count + 1) do |reference_index|
            reference = type_list + reference_list_offset + (reference_index * 12)
            _id, name_offset, attributes_and_offset = @bytes.unpack("@#{reference} n2 N")
            name = (@bytes.byteslice(map_offset + name_list_offset + name_offset + 1, @bytes.getbyte(map_offset + name_list_offset + name_offset)) unless name_offset == 0xFFFF)
            [name, data_offset + (attributes_and_offset & 0xFFFFFF) + 4]
          end
          chosen = index.is_a?(String) ? references.assoc(index) : references[index]
          raise Error, "No font #{index.inspect} in this resource file" unless chosen

          @offset_base = chosen[1]
          return chosen[1]
        end
        raise Error, "No sfnt resource in this resource file"
      end

      def read_unicode_cmap
        return @unicode_cmap if defined?(@unicode_cmap)

        cmap = table("cmap")
        subtable_count = cmap.unpack1("@2 n")
        candidates = Array.new(subtable_count) do |index|
          platform, encoding, offset = cmap.unpack("@#{4 + (index * 8)} n2 N")
          format = cmap.unpack1("@#{offset} n")
          next unless UNICODE_CMAP_FORMATS.include?(format)
          windows_unicode = platform == 3 && [1, 10].include?(encoding)
          next unless windows_unicode || platform.zero?

          [format, offset]
        end.compact
        format, offset = candidates.max_by(&:first)
        @unicode_cmap = format && parse_cmap(cmap, format, offset)
      end

      def parse_cmap(cmap, format, offset)
        glyph_by_code = {}
        case format
        when 4
          segment_count = cmap.unpack1("@#{offset + 6} n") / 2
          ends = cmap.unpack("@#{offset + 14} n#{segment_count}")
          starts_offset = offset + 16 + (segment_count * 2)
          starts = cmap.unpack("@#{starts_offset} n#{segment_count}")
          deltas = cmap.unpack("@#{starts_offset + (segment_count * 2)} n#{segment_count}")
          range_offsets_offset = starts_offset + (segment_count * 4)
          range_offsets = cmap.unpack("@#{range_offsets_offset} n#{segment_count}")
          segment_count.times do |segment|
            (starts[segment]..ends[segment]).each do |code|
              glyph =
                if range_offsets[segment].zero?
                  (code + deltas[segment]) & 0xFFFF
                else
                  glyph_offset = range_offsets_offset + (segment * 2) + range_offsets[segment] + ((code - starts[segment]) * 2)
                  raw = cmap.unpack1("@#{glyph_offset} n").to_i
                  raw.zero? ? 0 : (raw + deltas[segment]) & 0xFFFF
                end
              glyph_by_code[code] = glyph
            end
          end
        when 6
          first_code, count = cmap.unpack("@#{offset + 6} n2")
          count = [count, (cmap.bytesize - offset - 10) / 2].min
          cmap.unpack("@#{offset + 10} n#{count}").each_with_index { |glyph, index| glyph_by_code[first_code + index] = glyph }
        when 10
          first_code, count = cmap.unpack("@#{offset + 12} N2")
          count = [count, (cmap.bytesize - offset - 20) / 2].min
          cmap.unpack("@#{offset + 20} n#{count}").each_with_index { |glyph, index| glyph_by_code[first_code + index] = glyph }
        when 12
          group_count = [cmap.unpack1("@#{offset + 12} N"), (cmap.bytesize - offset - 16) / 12].min
          cmap.unpack("@#{offset + 16} N#{group_count * 3}").each_slice(3) do |start_code, end_code, start_glyph|
            (start_code..[end_code, MAXIMUM_CODE_POINT].min).each { |code| glyph_by_code[code] = start_glyph + (code - start_code) }
          end
        end
        glyph_by_code.each { |code, glyph| glyph_by_code[code] = 0 if glyph >= glyph_count }
        glyph_by_code.default = 0
        glyph_by_code.freeze
      end

      def name_string(name_id)
        name = table("name")
        return unless name

        count, strings_offset = name.unpack("@2 n2")
        records = Array.new(count) { |record_index| name.unpack("@#{6 + (record_index * 12)} n6") }
        record = records.find { |platform, _, _, id| id == name_id && platform == 3 } ||
          records.find { |platform, _, _, id| id == name_id && platform == 1 } ||
          records.find { |_, _, _, id| id == name_id }
        return unless record

        platform, _encoding, _language, _id, length, offset = record
        raw = name.byteslice(strings_offset + offset, length)
        (platform == 1) ? raw.force_encoding(::Encoding::MacRoman).encode(::Encoding::UTF_8) : raw.force_encoding(::Encoding::UTF_16BE).encode(::Encoding::UTF_8)
      rescue ::Encoding::UndefinedConversionError, ::Encoding::InvalidByteSequenceError
        nil
      end
    end
  end
end
