# frozen_string_literal: true

module Gamba
  # Gamba's own API, over a Prawn::Document that stays reachable through #prawn. Blocks receive this object,
  # options are keywords, and an unknown one raises instead of being ignored.
  class Document
    OPTIONS = %i[
      page_size page_layout margin left_margin right_margin top_margin bottom_margin background info print_scaling
      pdf_a lang
    ].freeze
    TEXT_ATTRIBUTES = %i[font size weight italic color align leading].freeze
    FONT_STYLES = %i[normal bold italic bold_italic].freeze
    # No Prawn page to match here, so fonts that have ligatures and GPOS kerning use them.
    DEFAULT_FONT_FEATURES = %i[liga kern].freeze
    DEFAULT_STYLE = :default

    attr_reader :prawn

    def initialize(prawn = nil, **options)
      @styles = {}
      @prawn = prawn || new_prawn_document(options)
    end

    def register_font(family, normal:, bold: nil, italic: nil, bold_italic: nil, features: DEFAULT_FONT_FEATURES)
      files = {normal:, bold:, italic:, bold_italic:}.compact
      prawn.font_families[family] = files.transform_values { |file| {file:, features:} }
      self
    end

    # Text attributes under a name: text "…", style: name. The :default style applies to every text.
    def style(name, **attributes)
      check_options(attributes, TEXT_ATTRIBUTES)
      @styles[name] = attributes.freeze
      self
    end

    def text(string, style: nil, **attributes)
      check_options(attributes, TEXT_ATTRIBUTES)
      attributes = {**@styles.fetch(DEFAULT_STYLE, {}), **named_style(style), **attributes}
      font = attributes.delete(:font)
      options = prawn_text_options(attributes)
      if font
        prawn.font(font, prawn.font_families.key?(font) ? {} : {features: DEFAULT_FONT_FEATURES}) { prawn.text(string, options) }
      else
        prawn.text(string, options)
      end
      self
    end

    # Draws anything that answers call(document): a document is made of small objects, each tested alone.
    def draw(component)
      component.call(self)
      self
    end

    def to_s
      prawn.render
    end

    def write(destination)
      if destination.respond_to?(:write)
        destination.write(to_s)
      else
        File.binwrite(destination, to_s)
      end
      self
    end

    private

    def new_prawn_document(options)
      check_options(options, OPTIONS)
      Prawn::Document.new(options)
    end

    def named_style(name)
      return {} unless name

      @styles.fetch(name) do
        raise ArgumentError, "unknown style #{name.inspect}: defined styles are #{@styles.keys.map(&:inspect).join(", ")}"
      end
    end

    def prawn_text_options(attributes)
      weight = attributes.delete(:weight) || :normal
      raise ArgumentError, "weight is #{weight.inspect}: accepted weights are :normal, :bold" unless %i[normal bold].include?(weight)

      font_style = FONT_STYLES[((weight == :bold) ? 1 : 0) + (attributes.delete(:italic) ? 2 : 0)]
      attributes[:style] = font_style unless font_style == :normal
      attributes.compact
    end

    def check_options(given, accepted)
      unknown = given.keys - accepted
      return if unknown.empty?

      raise ArgumentError, "unknown option#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}: " \
        "accepted options are #{accepted.map(&:inspect).join(", ")}"
    end
  end
end
