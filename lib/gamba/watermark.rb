# frozen_string_literal: true

module Gamba
  # A text across every page, beneath its content: watermark: "Draft", or a hash with the text and any of font, style,
  # size, angle (degrees), color and opacity. Each page calls its size's stamp as it opens, so the watermark lies
  # above a background and beneath what the page draws next; the stamp is drawn when the document renders, once its
  # fonts are registered.
  class Watermark
    OPTIONS = %i[text font style size angle color opacity].freeze
    STYLES = %i[normal bold italic bold_italic].freeze
    # Without a size, the rotated text spans at most this share of the page's width and height.
    FILL_RATIO = 0.8
    ARTIFACT = %i[Pagination Watermark].freeze
    # A page can open inside a block that changed the text state, which a form XObject inherits.
    TEXT_STATE_RESET = "0 Tr 0 Tc 0 Tw 100 Tz 0 Ts"

    def self.from_option(option)
      return unless option
      raise ArgumentError, "watermark is #{option.inspect}: give its text, or a hash with the text and its options" unless option.is_a?(String) || option.is_a?(Hash)

      option = {text: option} if option.is_a?(String)
      unknown = option.keys - OPTIONS
      raise ArgumentError, "unknown watermark option#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}: accepted options are #{OPTIONS.map(&:inspect).join(", ")}" if unknown.any?

      new(**option.compact)
    end

    def initialize(text:, font: nil, style: nil, size: nil, angle: nil, color: "808080", opacity: 0.2)
      @text = text.to_s
      raise ArgumentError, "the watermark text #{text.inspect} shows nothing" unless Tagging.visible_text?(@text)
      raise ArgumentError, "the watermark text #{text.inspect} holds a line break or a control character: it is one line" if @text.match?(/[[:cntrl:]  ]/)
      raise ArgumentError, "the watermark style is #{style.inspect}: give one of #{STYLES.map(&:inspect).join(", ")}" unless style.nil? || STYLES.include?(style)
      raise ArgumentError, "the watermark size is #{size.inspect}: give a positive number of points" if size && !(size.is_a?(Numeric) && size.finite? && size.positive?)
      raise ArgumentError, "the watermark angle is #{angle.inspect}: give a number of degrees" if angle && !(angle.is_a?(Numeric) && angle.finite?)
      raise ArgumentError, "the watermark opacity is #{opacity.inspect}: give a number from 0 to 1" unless opacity.is_a?(Numeric) && opacity.between?(0, 1)
      raise ArgumentError, "the watermark color is #{color.inspect}: give RGB as \"808080\" or CMYK as [0, 0, 0, 50]" unless color?(color)

      @font = font
      @style = style
      @size = size
      @angle = angle
      @color = color
      @opacity = opacity
      @unfilled_stamps = []
    end

    def open_page(document)
      _left, _bottom, width, height = document.page.dimensions
      name = "Gamba watermark #{width}x#{height}"
      @unfilled_stamps << [document.__send__(:create_stamp_dictionary, name), width, height] unless document.__send__(:stamp_dictionary_registry).key?(name)
      document.tag_artifact(*ARTIFACT) { document.stamp(name) }
    end

    def fill_stamps(document)
      @unfilled_stamps.each do |dictionary, width, height|
        document.page.stamp_stream(dictionary) { document.tag_artifact(*ARTIFACT) { draw(document, width, height) } }
      end
      @unfilled_stamps.clear
    end

    private

    def standard_font(document)
      message = "the watermark needs font: a registered TrueType or OpenType family, as PDF/A and PDF/UA embed every font"
      raise Prawn::Errors::PdfAViolation, message if document.pdf_a?
      raise Prawn::Errors::PdfUaViolation, message if document.pdf_ua?

      "Helvetica"
    end

    def color?(color)
      (color.is_a?(String) && color.match?(/\A\h{6}\z/)) || (color.is_a?(Array) && color.size == 4 && color.all?(Numeric))
    end

    # By default it runs along the page's diagonal, from the bottom left corner to the top right one.
    def draw(document, width, height)
      family = @font || document.default_font_family || standard_font(document)
      style = @style || (document.font_families.fetch(family, {}).key?(:bold) ? :bold : :normal)
      angle = @angle || (Math.atan2(height, width) * 180 / Math::PI)
      center_x = width / 2.0
      center_y = height / 2.0
      document.add_content(TEXT_STATE_RESET)
      document.canvas do
        document.font(family, style:) do
          document.font_size(@size || fitted_size(document, angle, width, height)) do
            kerning = document.default_kerning?
            font = document.font
            baseline = [center_x - (document.width_of(@text, kerning:) / 2), center_y - ((font.ascender - font.descender) / 2)]
            document.fill_color(@color)
            document.transparent(@opacity) { document.rotate(angle, origin: [center_x, center_y]) { document.draw_text(@text, at: baseline, kerning:) } }
          end
        end
      end
    end

    # The rotated box of the text, its width by the font's height, fits the share of the page FILL_RATIO leaves.
    def fitted_size(document, angle, width, height)
      radians = angle * Math::PI / 180
      cosine = Math.cos(radians).abs
      sine = Math.sin(radians).abs
      text_width = document.width_of(@text, size: 1, kerning: document.default_kerning?)
      raise ArgumentError, "the watermark text #{@text.inspect} has no width in #{document.font.name}" unless text_width.positive?

      text_height = document.font.height_at(1)
      [FILL_RATIO * width / ((text_width * cosine) + (text_height * sine)), FILL_RATIO * height / ((text_width * sine) + (text_height * cosine))].min
    end
  end
end
