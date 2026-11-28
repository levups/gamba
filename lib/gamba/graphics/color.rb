# frozen_string_literal: true

module Gamba
  # An ink of its own, by name, at a tint from 0 to 1, with the colour shown for it where the ink is not: made by
  # spot_color, given to fill_color and stroke_color.
  SpotColor = Data.define(:name, :alternate, :tint)
end

module Prawn
  module Graphics
    module Color
      COLOR_SPACES = %i[DeviceRGB DeviceCMYK Pattern].freeze
      OPERATOR_BY_TYPE = {fill: "scn", stroke: "SCN"}.freeze
      COLOR_SPACE_OPERATOR_BY_TYPE = {fill: "cs", stroke: "CS"}.freeze
      # A document uses a handful of colours; computed ones (gradients drawn by hand) must not grow it forever.
      HEX_COLORS_CACHED = 256
      PDF_OPERANDS_BY_HEX_COLOR = {}

      # A spot colour, printed with an ink of its own, at a tint from 0 to 1: give it to fill_color or stroke_color.
      # alternate is the CMYK (or, with rgb:, the RGB hex) that screens and proofs show for the full ink.
      def spot_color(name, cmyk: nil, rgb: nil, tint: 1)
        raise ArgumentError, "name is #{name.inspect}: give the ink's name, such as \"PANTONE 185 C\"" unless name.is_a?(String) && !name.empty?
        raise ArgumentError, "give the spot colour's alternate as cmyk: [c, m, y, k] or rgb: \"rrggbb\", one of them" unless cmyk.nil? ^ rgb.nil?
        raise ArgumentError, "tint is #{tint.inspect}: give a number from 0 to 1" unless tint.is_a?(Numeric) && tint.between?(0, 1)

        alternate = cmyk || rgb
        color_type(alternate) # raises on a malformed colour
        Gamba::SpotColor.new(name:, alternate:, tint: tint.to_f)
      end

      def fill_color(*color)
        return current_fill_color if color.empty?

        color = process_color(*color)
        refuse_cmyk_under_pdf_a(color)
        self.current_fill_color = color
        set_fill_color
      end
      alias_method :fill_color=, :fill_color

      def stroke_color(*color)
        return current_stroke_color if color.empty?

        color = process_color(*color)
        refuse_cmyk_under_pdf_a(color)
        self.current_stroke_color = color
        set_stroke_color(color)
      end
      alias_method :stroke_color=, :stroke_color

      module_function

      def rgb2hex(rgb)
        rgb.map { format("%02x", _1) }.join
      end

      def hex2rgb(hex)
        [hex[0..1], hex[2..3], hex[4..5]].map { _1.to_i(16) }
      end

      private

      def process_color(*color)
        case color.size
        when 1 then color[0]
        when 4 then color
        else raise ArgumentError, "wrong number of arguments supplied"
        end
      end

      def color_type(color)
        case color
        when Gamba::SpotColor then return :Spot
        when String
          return :RGB if /\A\h{6}\z/.match?(color)
        when Array
          return :RGB if color.length == 3
          return :CMYK if color.length == 4
        end
        raise ArgumentError, "Unknown type of color: #{color.inspect}"
      end

      def normalize_color(color)
        raise ArgumentError, "a spot colour paints flat: gradients take RGB or CMYK colours" if color.is_a?(Gamba::SpotColor)

        case color_type(color)
        when :RGB
          r, g, b = hex2rgb(color)
          [r / 255.0, g / 255.0, b / 255.0]
        when :CMYK
          color.map { _1 / 100.0 }
        end
      end

      def color_to_s(color)
        return PDF::Core.real(color.tint) if color.is_a?(Gamba::SpotColor)
        return PDF::Core.real_params(normalize_color(color)) unless color.is_a?(String)

        PDF_OPERANDS_BY_HEX_COLOR.fetch(color) do
          operands = PDF::Core.real_params(normalize_color(color))
          PDF_OPERANDS_BY_HEX_COLOR[color.dup.freeze] = operands if PDF_OPERANDS_BY_HEX_COLOR.size < HEX_COLORS_CACHED
          operands
        end
      end

      def color_space(color)
        return spot_color_space(color) if color.is_a?(Gamba::SpotColor)

        (color_type(color) == :RGB) ? :DeviceRGB : :DeviceCMYK
      end

      # A Separation colour space per ink, written once per document and named on each page that paints with it: its
      # tint goes linearly from none to the alternate colour. One name keeps one alternate.
      def spot_color_space(color)
        @spot_color_spaces ||= {}
        space = @spot_color_spaces[color.name] ||= begin
          rgb = color_type(color.alternate) == :RGB
          full = rgb ? normalize_color(color.alternate) : color.alternate.map { _1 / 100.0 }
          function = {FunctionType: 2, Domain: [0, 1], C0: [0] * full.size, C1: full, N: 1}
          reference = ref!([:Separation, PDF::Core::Name.new(value: color.name), rgb ? :DeviceRGB : :DeviceCMYK, function])
          {name: :"CS#{@spot_color_spaces.size}", alternate: color.alternate, reference:}
        end
        raise ArgumentError, "the spot colour #{color.name.inspect} was given another alternate before, #{space[:alternate].inspect}" unless space[:alternate] == color.alternate

        (page.resources[:ColorSpace] ||= {})[space[:name]] ||= space[:reference]
        space[:name]
      end

      # DeviceCMYK needs a CMYK output intent, and Gamba's PDF/A writes an sRGB one (ISO 19005-3 §6.2.4.3).
      def refuse_cmyk_under_pdf_a(color, description = "the color #{color.inspect}")
        return unless pdf_a?
        return refuse_cmyk_under_pdf_a(color.alternate, "the spot colour #{color.name.inspect}") if color.is_a?(Gamba::SpotColor)
        return unless color_type(color) == :CMYK

        raise Errors::PdfAViolation, "#{description} is CMYK, and PDF/A paints in the sRGB of its output intent: give it as RGB"
      end

      def set_color_space(type, color_space)
        return if current_color_space(type) == color_space && !page.in_stamp_stream?

        set_current_color_space(color_space, type)
        raise ArgumentError, "unknown color space: '#{color_space}'" unless COLOR_SPACES.include?(color_space) || color_space.to_s.start_with?("CS")

        operator = COLOR_SPACE_OPERATOR_BY_TYPE.fetch(type) { raise ArgumentError, "unknown type '#{type}'" }
        add_content("/#{color_space} #{operator}")
      end

      # A pattern paints until a colour of the same type replaces it. One the page's resources hold is recorded, to
      # paint with on the next page.
      def set_color(type, color, options = {})
        operator = OPERATOR_BY_TYPE.fetch(type) { raise ArgumentError, "unknown type '#{type}'" }
        if options[:pattern]
          reference = page.dictionary.data[:Resources]&.dig(:Pattern, color)
          set_color_space(type, :Pattern)
          add_content("/#{color} #{operator}")
          record_pattern(type, reference && {name: color, reference:})
        else
          refuse_cmyk_under_pdf_a(color)
          set_color_space(type, color_space(color))
          write_color(color_to_s(color), operator)
          state = graphic_state
          (type == :fill) ? state.fill_pattern &&= nil : state.stroke_pattern &&= nil
        end
      end

      # A pattern, {name:, reference:}, on this page's resources too.
      def write_pattern(type, pattern)
        (page.resources[:Pattern] ||= {})[pattern[:name]] ||= pattern[:reference]
        set_color_space(type, :Pattern)
        add_content("/#{pattern[:name]} #{OPERATOR_BY_TYPE.fetch(type)}")
        record_pattern(type, pattern)
      end

      def record_pattern(type, pattern)
        (type == :fill) ? graphic_state.fill_pattern = pattern : graphic_state.stroke_pattern = pattern
      end

      def write_fill_paint
        (pattern = graphic_state.fill_pattern) ? write_pattern(:fill, pattern) : set_fill_color
      end

      def write_stroke_paint
        (pattern = graphic_state.stroke_pattern) ? write_pattern(:stroke, pattern) : set_stroke_color
      end

      def set_fill_color(color = nil)
        set_color(:fill, color || current_fill_color)
      end

      def set_stroke_color(color = nil)
        set_color(:stroke, color || current_stroke_color)
      end

      def update_colors
        set_fill_color
        set_stroke_color
      end

      def current_color_space(type)
        graphic_state.color_space[type]
      end

      def set_current_color_space(color_space, type)
        graphic_state.color_space[type] = color_space
      end

      def current_fill_color
        graphic_state.fill_color
      end

      def current_fill_color=(color)
        graphic_state.fill_color = color
      end

      def current_stroke_color
        graphic_state.stroke_color
      end

      def current_stroke_color=(color)
        graphic_state.stroke_color = color
      end

      def write_color(color, operator)
        add_content("#{color} #{operator}")
      end
    end
  end
end
