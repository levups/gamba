# frozen_string_literal: true

module Prawn
  class Document
    DEFAULT_FONT_OPTIONS = {}.freeze
    BUILT_IN_FONT_FAMILIES = {
      "Courier" => {bold: "Courier-Bold", italic: "Courier-Oblique", bold_italic: "Courier-BoldOblique", normal: "Courier"},
      "Times-Roman" => {bold: "Times-Bold", italic: "Times-Italic", bold_italic: "Times-BoldItalic", normal: "Times-Roman"},
      "Helvetica" => {bold: "Helvetica-Bold", italic: "Helvetica-Oblique", bold_italic: "Helvetica-BoldOblique", normal: "Helvetica"}
    }.freeze

    def font(name = nil, options = DEFAULT_FONT_OPTIONS)
      return @font || font("Helvetica") if name.nil?
      raise Errors::NotOnPage if pages.empty? && !page.in_stamp_stream?

      new_font = find_font(name.to_s, options)
      if block_given?
        save_font do
          set_font(new_font, options[:size])
          yield
        end
      else
        set_font(new_font, options[:size])
      end
      @font
    end

    def font_size(points = nil)
      return @font_size unless points

      size_before_yield = @font_size
      @font_size = points
      return unless block_given?

      yield
      @font_size = size_before_yield
    end

    def font_size=(size)
      font_size(size)
    end

    def width_of(string, options = {})
      return width_of_string(string, options) unless options.key?(:inline_format)

      inline_format = options[:inline_format]
      arranger = Text::Formatted::Arranger.new(self, options)
      arranger.consumed = text_formatter.format(string, *(inline_format.is_a?(Array) ? inline_format : []))
      arranger.finalize_line
      arranger.line_width
    end

    def font_families
      @font_families ||= BUILT_IN_FONT_FAMILIES.transform_values(&:dup)
    end

    def set_font(font, size = nil)
      @font = font
      @font_size = size if size
    end

    def save_font
      @font ||= find_font("Helvetica")
      original_font = @font
      original_size = @font_size
      yield
    ensure
      set_font(original_font, original_size) if original_font
    end

    def find_font(name, options = {})
      if font_families.key?(name)
        family = name
        name = font_families[name][options[:style] || :normal]
        if name.is_a?(::Hash)
          options = options.merge(name)
          name = options[:file]
        end
      end
      key = "#{family}:#{name}:#{options[:font] || 0}:#{Array(options[:features]).join(",")}"
      return font_registry[key] = name if name.is_a?(Prawn::Font)

      font_registry[key] ||= Font.load(self, name, options.merge(family:))
    end

    def font_registry
      @font_registry ||= {}
    end

    private

    def width_of_string(string, options = {})
      font_metric_cache.width_of(string, options)
    end

    def font_metric_cache
      @font_metric_cache ||= FontMetricCache.new(self)
    end
  end

  # A font as a document uses it: metrics scaled to the document's current size, and its PDF resource.
  class Font
    attr_reader :name, :family, :options

    def self.load(document, source, options = {})
      case font_format(source, options)
      when "ttf" then outline_class(source, Fonts::TTF).new(document, source, options)
      when "otf" then outline_class(source, Fonts::OTF).new(document, source, options)
      when "dfont" then Fonts::DFont.new(document, source, options)
      when "ttc" then Fonts::TTC.new(document, source, options)
      else Fonts::AFM.new(document, source, options)
      end
    end

    # Outlines decide, not the extension: a .otf may hold TrueType outlines, and a .ttf CFF ones.
    def self.outline_class(source, by_extension)
      case (source.respond_to?(:read) ? :unknown : Gamba::TrueType::File.open(source).outline_format)
      when :true_type then Fonts::TTF
      when :open_type then Fonts::OTF
      else by_extension
      end
    end

    def self.font_format(source, options)
      return options.fetch(:format, "ttf") if source.respond_to?(:read)

      case source.to_s
      when /\.ttf$/i then "ttf"
      when /\.otf$/i then "otf"
      when /\.dfont$/i then "dfont"
      when /\.ttc$/i then "ttc"
      else "afm"
      end
    end

    def initialize(document, name, options = {})
      @document = document
      @name = name
      @options = options
      @family = options[:family]
      @identifier = generate_unique_id
      @references = {}
      @subset_name_cache = {}
      @full_font_embedding = options.key?(:subset) && !options[:subset]
    end

    def ascender
      @ascender / 1000.0 * size
    end

    def descender
      -@descender / 1000.0 * size
    end

    def line_gap
      @line_gap / 1000.0 * size
    end

    def height_at(size)
      @normalized_height ||= (@ascender - @descender + @line_gap) / 1000.0
      @normalized_height * size
    end

    def height
      height_at(size)
    end

    # The string in the font's encoding, only to be measured: TTF reads a UTF-8 string as it is, without a copy.
    def measured_string(string)
      normalize_encoding(string)
    end

    def add_to_current_page(subset)
      @references[subset] ||= register(subset)
      @document.page.fonts[identifier_for(subset)] = @references[subset]
    end

    def identifier_for(subset)
      @subset_name_cache[subset] ||= @full_font_embedding ? @identifier.to_sym : :"#{@identifier}.#{subset}"
    end

    def inspect
      "#{self.class.name}< #{name}: #{size} >"
    end

    def hash
      [self.class, name, family].hash
    end

    def eql?(other)
      self.class == other.class && name == other.name && family == other.family && size == other.size
    end

    protected

    def size
      @document.font_size
    end

    private

    def generate_unique_id
      font_count = @document.font_registry.size + 1
      font_count += 1 until @document.page.fonts.keys.none? { _1.to_s.start_with?("F#{font_count}.") }
      :"F#{font_count}"
    end
  end

  # Widths of strings, cached per font, size and options: text layout measures the same words again and again.
  # Nested hashes, so a lookup hashes the string only.
  class FontMetricCache
    def initialize(document)
      @document = document
      @width_by_string_by_settings = Hash.new { |cache, settings| cache[settings] = {} }.compare_by_identity
    end

    def width_of(string, options)
      font = options[:style] ? @document.find_font(@document.font.family, style: options[:style]) : @document.font
      encoded_string = font.measured_string(string)
      width = width_by_string(font, @document.font_size, options[:size], options[:kerning])[encoded_string] ||=
        font.compute_width_of(encoded_string, options)
      character_count = @document.font.character_count(encoded_string)
      character_count.positive? ? width + (@document.character_spacing * (character_count - 1)) : width
    end

    private

    # The table of the last settings stays at hand: the words of a paragraph are all measured with the same ones.
    def width_by_string(font, font_size, size, kerning)
      unless font.equal?(@last_font) && font_size.eql?(@last_font_size) && size.eql?(@last_size) && kerning.eql?(@last_kerning)
        @last_font, @last_font_size, @last_size, @last_kerning = font, font_size, size, kerning
        @last_width_by_string = @width_by_string_by_settings[font][[font_size, size, kerning]] ||= {}
      end
      @last_width_by_string
    end
  end
end
