# frozen_string_literal: true

module PrawnX
  module TrueType
    # A new TrueType font holding only the glyphs a document uses, numbered in the order it first used them
    # (glyph 0, .notdef, stays first). Composite glyphs bring their components along.
    class Subset
      # Tables ISO 32000-1 §9.9 requires in an embedded TrueType font, plus OS/2 and post for strict readers, and
      # gasp, which tells rasterizers like Poppler at which sizes to hint and smooth glyphs.
      COPIED_TABLES = %w[cvt\  fpgm prep OS/2 gasp].freeze
      # Composite glyph flags (OpenType 'glyf' table).
      ARGUMENTS_ARE_WORDS = 0x0001
      HAS_SCALE = 0x0008
      MORE_COMPONENTS = 0x0020
      HAS_X_AND_Y_SCALE = 0x0040
      HAS_TWO_BY_TWO = 0x0080
      CHECKSUM_MAGIC = 0xB1B0AFBA

      def initialize(file)
        @file = file
        @new_glyph_by_original = {0 => 0}
      end

      def glyph_for(original_glyph)
        @new_glyph_by_original[original_glyph] ||= @new_glyph_by_original.size
      end

      def original_glyphs
        @new_glyph_by_original.keys
      end

      # Numbers the components of composite glyphs, level by level, in the order of their composites' indices.
      def add_components(originals)
        level = originals
        loop do
          components = level.flat_map { component_glyphs(@file.glyph_data(_1)) }
          break if components.empty?

          components.each { glyph_for(_1) }
          level = components
        end
      end

      def bytes(extra_tables = {})
        glyphs = glyph_data_including_components
        offsets = [0]
        glyf = glyphs.each_with_object(+"".b) do |data, table|
          table << data << ("\x00" * ((4 - (data.bytesize % 4)) % 4))
          offsets << table.bytesize
        end
        glyph_count = glyphs.size
        widths = @file.advance_widths
        left_side_bearings = original_glyphs.map { left_side_bearing(_1) }

        bounds = glyphs.filter_map { |glyph| glyph.unpack("s>5") if glyph.bytesize >= 10 }
        advances = original_glyphs.map { widths[_1] }
        tables = {
          "head" => head_table(bounds),
          "hhea" => horizontal_header(bounds, advances, left_side_bearings, glyph_count),
          "maxp" => maximum_profile(bounds, glyphs, glyph_count),
          "hmtx" => horizontal_metrics(original_glyphs, widths, left_side_bearings),
          "loca" => offsets.pack("N*"),
          "glyf" => glyf,
          "post" => @file.table("post").byteslice(0, 32).dup.tap { |post| post[0, 4] = "\x00\x03\x00\x00".b }
        }
        COPIED_TABLES.each { |tag| tables[tag] = @file.table(tag) if @file.table?(tag) }
        Subset.assemble(tables.merge(extra_tables))
      end

      # An sfnt file of these tables, with its directory and checksums (OpenType specification, "Font file").
      def self.assemble(tables, sfnt_version: 0x00010000)
        tags = tables.keys.sort
        table_count = tags.size
        search_range = (2**Math.log2(table_count).floor) * 16
        directory = [sfnt_version, table_count, search_range, Math.log2(search_range / 16).to_i, (table_count * 16) - search_range].pack("Nn4")
        body = +"".b
        offset = 12 + (table_count * 16)
        tags.each do |tag|
          data = tables[tag]
          directory << [tag, Subset.checksum(data), offset + body.bytesize, data.bytesize].pack("a4N3")
          body << data << ("\x00" * ((4 - (data.bytesize % 4)) % 4))
        end
        font = directory << body
        head_offset = 12 + (table_count * 16) + tags.take_while { _1 != "head" }.sum { |tag| (tables[tag].bytesize + 3) & ~3 }
        font[head_offset + 8, 4] = [(CHECKSUM_MAGIC - Subset.checksum(font)) & 0xFFFFFFFF].pack("N")
        font
      end

      def self.checksum(data)
        padded = data + ("\x00" * ((4 - (data.bytesize % 4)) % 4))
        padded.unpack("N*").sum & 0xFFFFFFFF
      end

      private

      def glyph_data_including_components
        glyphs = []
        index = 0
        while index < original_glyphs.size
          glyphs << remap_components(@file.glyph_data(original_glyphs[index]))
          index += 1
        end
        glyphs
      end

      def component_glyphs(data)
        return [] if data.bytesize < 10 || data.unpack1("s>") >= 0

        glyphs = []
        position = 10
        loop do
          break if position + 4 > data.bytesize

          flags, original = data.unpack("@#{position} n2")
          glyphs << original if original < @file.glyph_count
          position += 4 + ((flags & ARGUMENTS_ARE_WORDS).zero? ? 2 : 4)
          position += 2 if (flags & HAS_SCALE).nonzero?
          position += 4 if (flags & HAS_X_AND_Y_SCALE).nonzero?
          position += 8 if (flags & HAS_TWO_BY_TWO).nonzero?
          break if (flags & MORE_COMPONENTS).zero?
        end
        glyphs
      end

      def remap_components(data)
        return data if data.bytesize < 10 || data.unpack1("s>") >= 0

        data = data.dup
        position = 10
        loop do
          raise Error, "Truncated composite glyph" if position + 4 > data.bytesize

          flags, original = data.unpack("@#{position} n2")
          raise Error, "Composite glyph component #{original} beyond the font's #{@file.glyph_count} glyphs" if original >= @file.glyph_count

          data[position + 2, 2] = [glyph_for(original)].pack("n")
          position += 4 + ((flags & ARGUMENTS_ARE_WORDS).zero? ? 2 : 4)
          position += 2 if (flags & HAS_SCALE).nonzero?
          position += 4 if (flags & HAS_X_AND_Y_SCALE).nonzero?
          position += 8 if (flags & HAS_TWO_BY_TWO).nonzero?
          break if (flags & MORE_COMPONENTS).zero?
        end
        data
      end

      # Each glyph's advance width then left side bearing, packed: one array, no pairs to flatten.
      def horizontal_metrics(original_glyphs, widths, left_side_bearings)
        metrics = []
        original_glyphs.each_with_index { |glyph, index| metrics.push(widths[glyph], left_side_bearings[index]) }
        metrics.pack("n*")
      end

      def left_side_bearing(glyph)
        metric_count = @file.table("hhea").unpack1("@34 n")
        hmtx = @file.table("hmtx")
        raw = (glyph < metric_count) ? hmtx.unpack1("@#{(glyph * 4) + 2} n") : hmtx.unpack1("@#{(metric_count * 4) + ((glyph - metric_count) * 2)} n")
        raw.to_i
      end

      # The subset's own extremes, as the OpenType specification defines them: readers like Poppler size their
      # glyph caches from the font's bounding box.
      def head_table(bounds)
        head = @file.table("head").dup
        head[8, 4] = "\x00\x00\x00\x00".b
        head[36, 8] = [bounds.map { _1[1] }.min || 0, bounds.map { _1[2] }.min || 0, bounds.map { _1[3] }.max || 0, bounds.map { _1[4] }.max || 0].pack("s>4")
        head[50, 2] = [1].pack("n")
        head
      end

      def horizontal_header(bounds, advances, left_side_bearings, glyph_count)
        hhea = @file.table("hhea").dup
        right_side_bearings = bounds.zip(advances).filter_map { |bound, advance| advance - (bound[3] - bound[1]) - bound[1] if bound && advance }
        extents = bounds.map { _1[3] }
        hhea[10, 8] = [advances.compact.max || 0, left_side_bearings.min || 0, right_side_bearings.min || 0, extents.max || 0].pack("n s>3")
        hhea[34, 2] = [glyph_count].pack("n")
        hhea
      end

      # Largest simple glyph, in points and contours; composite figures stay those of the whole font.
      def maximum_profile(bounds, glyphs, glyph_count)
        maxp = @file.table("maxp").dup
        maxp[4, 2] = [glyph_count].pack("n")
        return maxp if maxp.bytesize < 10

        simple = glyphs.select { |glyph| glyph.bytesize >= 10 && glyph.unpack1("s>") >= 0 }
        contours = simple.map { _1.unpack1("s>") }
        points = simple.zip(contours).map! { |glyph, count| count.zero? ? 0 : glyph.unpack1("@#{10 + ((count - 1) * 2)} n") + 1 }
        maxp[6, 4] = [points.max || 0, contours.max || 0].pack("n2")
        maxp
      end
    end
  end
end
