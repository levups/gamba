# frozen_string_literal: true

module Gamba
  # A text across every page, beneath its content: Prawn::Document.new(watermark: "Draft"), or a hash with the
  # text and any of font, style, size, angle (degrees), color and opacity. Written once per page size.
  module Watermark
    OPTIONS = %i[text font style size angle color opacity].freeze
    DEFAULTS = {style: :bold, color: "808080", opacity: 0.2}.freeze
    # Without a size, the text spans this share of the line through the page's centre at its angle.
    SPAN_RATIO = 0.8

    private

    def initialize_watermark(watermark)
      return unless watermark

      watermark = {text: watermark} unless watermark.is_a?(Hash)
      unknown = watermark.keys - OPTIONS
      raise ArgumentError, "unknown watermark option#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}: accepted options are #{OPTIONS.map(&:inspect).join(", ")}" if unknown.any?
      raise ArgumentError, "the watermark has no text" if watermark[:text].to_s.empty?

      @watermark = DEFAULTS.merge(watermark)
      @unfilled_watermark_page_by_stamp = {}
    end

    # Each page calls its size's stamp as soon as it opens, so the watermark lies beneath whatever it draws next;
    # the stamp is drawn when the document renders, once its fonts are registered.
    def draw_watermark
      return unless @watermark

      _left, _bottom, width, height = page.dimensions
      name = "Gamba watermark #{width}x#{height}"
      unless stamp_dictionary_registry.key?(name)
        create_stamp_dictionary(name)
        @unfilled_watermark_page_by_stamp[name] = page_number
      end
      tag_artifact(:Pagination, :Watermark) { stamp(name) }
    end

    def fill_watermark_stamps
      return unless @watermark

      @unfilled_watermark_page_by_stamp.each do |name, page_number|
        go_to_page(page_number)
        page.stamp_stream(stamp_dictionary_registry.fetch(name)[:stamp_dictionary]) { tag_artifact(:Pagination, :Watermark) { draw_watermark_text } }
      end
      @unfilled_watermark_page_by_stamp.clear
    end

    # By default it runs along the page's diagonal, from the bottom left corner to the top right one.
    def draw_watermark_text
      _left, _bottom, width, height = page.dimensions
      text = @watermark[:text].to_s
      angle = @watermark[:angle] || (Math.atan2(height, width) * 180 / Math::PI)
      center = [width / 2.0, height / 2.0]
      canvas do
        font(@watermark[:font] || @default_font_family || font.family, style: @watermark[:style]) do
          font_size(@watermark[:size] || fitted_watermark_size(text, angle, width, height)) do
            baseline = [center[0] - (width_of(text) / 2), center[1] - ((font.ascender + font.descender) / 2)]
            fill_color @watermark[:color]
            transparent(@watermark[:opacity]) { rotate(angle, origin: center) { draw_text(text, at: baseline) } }
          end
        end
      end
    end

    def fitted_watermark_size(text, angle, width, height)
      radians = angle * Math::PI / 180
      half_line = [(width / 2.0) / Math.cos(radians).abs, (height / 2.0) / Math.sin(radians).abs].min
      2 * half_line * SPAN_RATIO / width_of(text, size: 1)
    end
  end
end
