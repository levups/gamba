# frozen_string_literal: true

module PrawnX
  module TrueType
    # The parts of OpenType's GSUB and GPOS tables (OpenType specification, "OpenType Layout") PrawnX applies on
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
      end

      # Glyphs and the characters each stands for, ligatures applied: [[glyph, [code, …]], …].
      def shape(codes)
        clusters = codes.map { [@file.glyph_by_code[it], [it]] }
        return clusters if @ligatures_by_first_glyph.empty?

        shaped = []
        index = 0
        while index < clusters.size
          ligature = (@ligatures_by_first_glyph[clusters[index][0]] || []).find do |components, _|
            components.each_with_index.all? { |component, offset| clusters[index + 1 + offset]&.first == component }
          end
          if ligature
            components, glyph = ligature
            shaped << [glyph, clusters[index, components.size + 1].flat_map(&:last)]
            index += components.size + 1
          else
            shaped << clusters[index]
            index += 1
          end
        end
        shaped
      end

      # The horizontal advance adjustment between two glyphs, in font units, or nil.
      def kerning(left, right)
        @pair_lookups.each do |lookup|
          adjustment = lookup.call(left, right)
          return adjustment if adjustment
        end
        nil
      end

      private

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
        ligatures.transform_values { |list| list.sort_by { -it[0].size } }
      end

      def read_pair_lookups
        table = @file.table("GPOS")
        return [] unless table && @features.include?("kern")

        lookups(table, "kern", PAIR_ADJUSTMENT, GPOS_EXTENSION).filter_map { pair_lookup(table, it) }
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
            record = (0...count).find { table.unpack1("@#{set + 2 + (it * (record_size + 2))} n") == right }
            record && table.unpack1("@#{set + 4 + (record * (record_size + 2)) + advance_position} s>")
          end
        when 2
          first_classes = class_definition(table, subtable + table.unpack1("@#{subtable + 8} n"))
          second_classes = class_definition(table, subtable + table.unpack1("@#{subtable + 10} n"))
          _first_count, second_count = table.unpack("@#{subtable + 12} n2")
          lambda do |left, right|
            next unless coverage[left]

            record = (first_classes[left] * second_count) + second_classes[right]
            table.unpack1("@#{subtable + 16 + (record * record_size) + advance_position} s>").then { it.zero? ? nil : it }
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
        offset_by_tag = Array.new(script_count) { table.unpack("@#{script_list + 2 + (it * 6)} a4 n") }.to_h
        script_offset = offset_by_tag.values_at(*PREFERRED_SCRIPTS).find { !it.nil? } || offset_by_tag.values.first
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
            (first..last).each { index[it] = start_index + (it - first) }
          end
        end
      end

      def class_definition(table, offset)
        classes = Hash.new(0)
        format = table.unpack1("@#{offset} n")
        if format == 1
          start, count = table.unpack("@#{offset + 2} n2")
          table.unpack("@#{offset + 6} n#{count}").each { classes[start + it[1]] = it[0] }
        else
          count = table.unpack1("@#{offset + 2} n")
          table.unpack("@#{offset + 4} n#{count * 3}").each_slice(3) { |first, last, value| (first..last).each { classes[it] = value } }
        end
        classes
      end
    end
  end
end
