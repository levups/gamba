# frozen_string_literal: true

module Prawn
  module Fonts
    # The 14 standard PDF fonts, measured from Adobe's AFM files and written in WinAnsiEncoding.
    class AFM < Font
      BUILT_INS = %w[
        Courier Helvetica Times-Roman Symbol ZapfDingbats Courier-Bold Courier-Oblique Courier-BoldOblique Times-Bold
        Times-Italic Times-BoldItalic Helvetica-Bold Helvetica-Oblique Helvetica-BoldOblique
      ].freeze
      METRICS_BY_PATH = {}
      METRICS_LOCK = Mutex.new

      Metrics = Data.define(:width_by_byte, :kerning_by_byte_pair, :attributes)

      class << self
        attr_accessor :hide_m17n_warning
      end
      self.hide_m17n_warning = false

      def self.metrics_path
        @metrics_path ||= ENV["METRICS"]&.split(":") ||
          [".", "/usr/lib/afm", "/usr/local/lib/afm", "/usr/openwin/lib/fonts/afm", "#{Prawn::DATADIR}/fonts"]
      end

      attr_reader :attributes

      def initialize(document, name, options = {})
        name ||= options[:family]
        raise Errors::UnknownFont, "#{name} (#{options[:style] || "normal"}) is not a known font." unless BUILT_INS.include?(name)
        if document.pdf_a?
          raise Errors::PdfAViolation, "PDF/A embeds every font, which #{name}, a standard PDF font, cannot be: use a TrueType or OpenType font"
        end

        super
        file_name = @name.end_with?(".afm") ? @name : "#{@name}.afm"
        file_name = find_font(file_name) unless file_name.start_with?("/")
        metrics = METRICS_LOCK.synchronize { METRICS_BY_PATH[file_name] ||= parse_afm(file_name) }
        @width_by_byte = metrics.width_by_byte
        @kerning_by_byte_pair = metrics.kerning_by_byte_pair
        @attributes = metrics.attributes
        @ascender = Integer(@attributes.fetch("ascender", "0"), 10)
        @descender = Integer(@attributes.fetch("descender", "0"), 10)
        @line_gap = Float(bbox[3] - bbox[1]) - (@ascender - @descender)
      end

      def unicode?
        false
      end

      def bbox
        @bbox ||= @attributes["fontbbox"].split(/\s+/).map { Integer(_1) }
      end

      def compute_width_of(string, options = {})
        scale = (options[:size] || size) / 1000.0
        return unscaled_width_of(string) * scale unless options[:kerning]

        strings, offsets = kern(string).partition { _1.is_a?(String) }
        (unscaled_width_of(strings.join) - offsets.sum) * scale
      end

      def has_kerning_data?
        !@kerning_by_byte_pair.empty?
      end

      def normalize_encoding(text)
        text.encode(::Encoding::Windows_1252)
      rescue ::Encoding::InvalidByteSequenceError, ::Encoding::UndefinedConversionError
        raise Errors::IncompatibleStringEncoding,
          "Your document includes text that's not compatible with the Windows-1252 character set.\n" \
          "If you need full UTF-8 support, use external fonts instead of PDF's built-in fonts.\n"
      end

      def to_utf8(text)
        text.encode(::Encoding::UTF_8)
      end

      def character_count(string)
        string.length
      end

      def encode_text(text, options = {})
        [[0, options[:kerning] ? kern(text) : text]]
      end

      def glyph_present?(character)
        !normalize_encoding(character).nil?
      rescue Errors::IncompatibleStringEncoding
        false
      end

      private

      def register(_subset)
        dictionary = {Type: :Font, Subtype: :Type1, BaseFont: name.to_sym}
        dictionary[:Encoding] = :WinAnsiEncoding unless symbolic?
        @document.ref!(dictionary)
      end

      def symbolic?
        attributes["characterset"] == "Special"
      end

      def find_font(file)
        directory = self.class.metrics_path.find { |path| File.exist?("#{path}/#{file}") }
        raise Errors::UnknownFont, "Couldn't find the font: #{file} in any of:\n#{self.class.metrics_path.join("\n")}" unless directory

        "#{directory}/#{file}"
      end

      # Runs of bytes, separated by the kerning offset between two of them, in thousandths of the font size.
      def kern(string)
        runs = [String.new(encoding: ::Encoding::BINARY)]
        last_byte = nil
        string.each_byte do |byte|
          offset = last_byte && @kerning_by_byte_pair[(last_byte << 8) | byte]
          runs << -offset << String.new(encoding: ::Encoding::BINARY) if offset
          runs.last << byte
          last_byte = byte
        end
        runs.map { |run| run.is_a?(String) ? run.force_encoding(::Encoding::Windows_1252) : run }
      end

      def unscaled_width_of(string)
        string.each_byte.sum { @width_by_byte[_1] }
      end

      def parse_afm(file_name)
        width_by_name = {}
        kerning_by_name_pair = {}
        attributes = {}
        sections = []
        File.foreach(file_name) do |line|
          if (section = line[/^Start(\w+)/, 1])
            sections.push(section)
          elsif line.start_with?("End")
            sections.pop
          else
            case sections
            when %w[FontMetrics CharMetrics]
              next unless /^CH?\s/.match?(line)

              width_by_name[line[/\bN\s+(\.?\w+)\s*;/, 1]] = Integer(line[/\bWX\s+(\d+)\s*;/, 1], 10)
            when %w[FontMetrics KernData KernPairs]
              next unless line =~ /^KPX\s+(\.?\w+)\s+(\.?\w+)\s+(-?\d+)/

              kerning_by_name_pair[[$1, $2]] = Integer($3, 10)
            when %w[FontMetrics KernData TrackKern], %w[FontMetrics Composites]
              next
            else
              next unless line =~ /(^\w+)\s+(.*)/

              key = $1.downcase
              attributes[key] = attributes[key] ? [*attributes[key], $2] : $2
            end
          end
        end

        byte_by_name = Encoding::WinAnsi::CHARACTERS.each_with_index.to_h
        kerning_by_byte_pair = kerning_by_name_pair.each_with_object({}) do |((left, right), offset), table|
          left_byte = byte_by_name[left]
          right_byte = byte_by_name[right]
          table[(left_byte << 8) | right_byte] = offset if left_byte && right_byte
        end
        width_by_byte = Encoding::WinAnsi::CHARACTERS.map { width_by_name.fetch(_1, 0) }
        Metrics.new(width_by_byte: width_by_byte.freeze, kerning_by_byte_pair: kerning_by_byte_pair.freeze, attributes: attributes.freeze)
      end
    end
  end
end
