# frozen_string_literal: true

module Gamba
  module TrueType
    # The parts of OpenType's GSUB and GPOS tables (OpenType specification, "OpenType Layout") Gamba applies on
    # request: ligatures (GSUB lookup type 4) and pair kerning (GPOS lookup type 2), for the font's Latin script.
    class OpenTypeLayout
      LIGATURE_SUBSTITUTION = 4
      GSUB_EXTENSION = 7
      PAIR_ADJUSTMENT = 2
      GPOS_EXTENSION = 9
      X_ADVANCE = 0x0004
      PREFERRED_SCRIPTS = ["latn", "DFLT"].freeze

      def initialize(file, features)
        @file = file
        @features = features.map(&:to_s)
        @ligatures_by_first_glyph = read_ligatures
        @pair_lookups = read_pair_lookups
        @kerning_by_pair = {}
      end

      # Glyphs and the characters each stands for, ligatures applied: [[glyph, code or [code, …]], …], a glyph
      # standing for one character carrying its code alone, as unshaped text does.
      def shape(codes)
        shaped = []
        each_glyph(codes) { |glyph, index, length| shaped << [glyph, self.class.cluster_codes(codes, index, length)] }
        shaped
      end

      def self.cluster_codes(codes, index, length)
        (length == 1) ? codes[index] : codes[index, length]
      end

      # Each glyph, ligatures applied, with the index of its first character and how many it stands for. Text is
      # measured word by word: this builds nothing for the glyphs of a word.
      def each_glyph(codes)
        glyph_by_code = @file.glyph_by_code
        index = 0
        while index < codes.size
          glyph = glyph_by_code[codes[index]]
          ligature = ligature_at(codes, index, glyph, glyph_by_code)
          if ligature
            length = ligature[0].size + 1
            yield ligature[1], index, length
          else
            length = 1
            yield glyph, index, length
          end
          index += length
        end
      end

      # The horizontal advance adjustment between two glyphs, in font units, or nil. Each pair is read from the
      # font once: a document kerns the same pairs over and over.
      def kerning(left, right)
        pair = (left << 16) | right
        adjustment = @kerning_by_pair.fetch(pair) { @kerning_by_pair[pair] = pair_adjustment(left, right) || false }
        adjustment || nil
      end

      private

      # The longest ligature starting with this glyph whose other components follow it: [components, glyph].
      def ligature_at(codes, index, glyph, glyph_by_code)
        @ligatures_by_first_glyph[glyph]&.find do |components, _ligature_glyph|
          next false if index + components.size >= codes.size

          matched = 0
          matched += 1 while matched < components.size && glyph_by_code[codes[index + 1 + matched]] == components[matched]
          matched == components.size
        end
      end

      def pair_adjustment(left, right)
        @pair_lookups.each do |lookup|
          adjustment = lookup.call(left, right)
          return adjustment if adjustment
        end
        nil
      end

      def read_ligatures
        table = @file.table("GSUB")
        return {} unless table && @features.include?("liga")

        ligatures = Hash.new { |hash, glyph| hash[glyph] = [] }
        lookups(table, "liga", LIGATURE_SUBSTITUTION, GSUB_EXTENSION).each do |subtable|
          next unless table.unpack1("@#{subtable} n") == 1

          coverage = coverage_glyphs(table, subtable + table.unpack1("@#{subtable + 2} n"))
          set_count = table.unpack1("@#{subtable + 4} n")
          table.unpack("@#{subtable + 6} n#{set_count}").each_with_index do |set_offset, index|
            set = subtable + set_offset
            table.unpack("@#{set + 2} n#{table.unpack1("@#{set} n")}").each do |ligature_offset|
              ligature = set + ligature_offset
              glyph, component_count = table.unpack("@#{ligature} n2")
              ligatures[coverage[index]] << [table.unpack("@#{ligature + 4} n#{component_count - 1}"), glyph]
            end
          end
        end
        ligatures.transform_values { |list| list.sort_by { |components, _glyph| -components.size } }
      end

      def read_pair_lookups
        table = @file.table("GPOS")
        return [] unless table && @features.include?("kern")

        lookups(table, "kern", PAIR_ADJUSTMENT, GPOS_EXTENSION).filter_map { pair_lookup(table, _1) }
      end

      def pair_lookup(table, subtable)
        format, coverage_offset, first_format, second_format = table.unpack("@#{subtable} n4")
        return unless (first_format & X_ADVANCE).nonzero?

        coverage = coverage_index(table, subtable + coverage_offset)
        advance_position = 2 * (first_format & (X_ADVANCE - 1)).digits(2).count(1)
        record_size = 2 * (first_format.digits(2).count(1) + second_format.digits(2).count(1))
        case format
        when 1
          set_offsets = table.unpack("@#{subtable + 10} n#{table.unpack1("@#{subtable + 8} n")}")
          lambda do |left, right|
            index = coverage[left]
            next unless index

            set = subtable + set_offsets[index]
            count = table.unpack1("@#{set} n")
            record = (0...count).find { |candidate| table.unpack1("@#{set + 2 + (candidate * (record_size + 2))} n") == right }
            record && table.unpack1("@#{set + 4 + (record * (record_size + 2)) + advance_position} s>")
          end
        when 2
          first_classes = class_definition(table, subtable + table.unpack1("@#{subtable + 8} n"))
          second_classes = class_definition(table, subtable + table.unpack1("@#{subtable + 10} n"))
          _first_count, second_count = table.unpack("@#{subtable + 12} n2")
          lambda do |left, right|
            next unless coverage[left]

            record = (first_classes[left] * second_count) + second_classes[right]
            table.unpack1("@#{subtable + 16 + (record * record_size) + advance_position} s>").then { |adjustment| adjustment.zero? ? nil : adjustment }
          end
        end
      end

      # Subtables of the lookups a feature uses for the preferred script's default language, of the given type.
      def lookups(table, feature_tag, type, extension_type)
        script_list, feature_list, lookup_list = table.unpack("@4 n3")
        feature_indices = default_language_features(table, script_list)
        feature_count = table.unpack1("@#{feature_list} n")
        lookup_indices = feature_indices.flat_map do |feature_index|
          next [] if feature_index >= feature_count

          tag, offset = table.unpack("@#{feature_list + 2 + (feature_index * 6)} a4 n")
          next [] unless tag == feature_tag

          feature = feature_list + offset
          table.unpack("@#{feature + 4} n#{table.unpack1("@#{feature + 2} n")}")
        end
        lookup_indices.uniq.flat_map do |lookup_index|
          lookup = lookup_list + table.unpack1("@#{lookup_list + 2 + (lookup_index * 2)} n")
          lookup_type, _flags, subtable_count = table.unpack("@#{lookup} n3")
          table.unpack("@#{lookup + 6} n#{subtable_count}").filter_map do |offset|
            subtable = lookup + offset
            if lookup_type == extension_type
              actual_type, extension_offset = table.unpack("@#{subtable + 2} n N")
              subtable + extension_offset if actual_type == type
            elsif lookup_type == type
              subtable
            end
          end
        end
      end

      def default_language_features(table, script_list)
        script_count = table.unpack1("@#{script_list} n")
        offset_by_tag = Array.new(script_count) { |script_index| table.unpack("@#{script_list + 2 + (script_index * 6)} a4 n") }.to_h
        script_offset = offset_by_tag.values_at(*PREFERRED_SCRIPTS).find { !_1.nil? } || offset_by_tag.values.first
        return [] unless script_offset

        script = script_list + script_offset
        language_offset = table.unpack1("@#{script} n")
        return [] if language_offset.zero?

        language = script + language_offset
        table.unpack("@#{language + 6} n#{table.unpack1("@#{language + 4} n")}")
      end

      def coverage_glyphs(table, offset)
        coverage_index(table, offset).sort_by(&:last).map(&:first)
      end

      def coverage_index(table, offset)
        format, count = table.unpack("@#{offset} n2")
        if format == 1
          table.unpack("@#{offset + 4} n#{count}").each_with_index.to_h
        else
          table.unpack("@#{offset + 4} n#{count * 3}").each_slice(3).each_with_object({}) do |(first, last, start_index), index|
            (first..last).each { |glyph| index[glyph] = start_index + (glyph - first) }
          end
        end
      end

      def class_definition(table, offset)
        classes = Hash.new(0)
        format = table.unpack1("@#{offset} n")
        if format == 1
          start, count = table.unpack("@#{offset + 2} n2")
          table.unpack("@#{offset + 6} n#{count}").each_with_index { |glyph_class, index| classes[start + index] = glyph_class }
        else
          count = table.unpack1("@#{offset + 2} n")
          table.unpack("@#{offset + 4} n#{count * 3}").each_slice(3) { |first, last, value| (first..last).each { classes[_1] = value } }
        end
        classes
      end
    end
  end
end
