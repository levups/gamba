# frozen_string_literal: true

module Prawn
  module Graphics
    module Color
      COLOR_SPACES = %i[DeviceRGB DeviceCMYK Pattern].freeze
      OPERATOR_BY_TYPE = {fill: "scn", stroke: "SCN"}.freeze
      COLOR_SPACE_OPERATOR_BY_TYPE = {fill: "cs", stroke: "CS"}.freeze
      # A document uses a handful of colours; computed ones (gradients drawn by hand) must not grow it forever.
      HEX_COLORS_CACHED = 256
      PDF_OPERANDS_BY_HEX_COLOR = {}

      def fill_color(*color)
        return current_fill_color if color.empty?

        self.current_fill_color = process_color(*color)
        set_fill_color
      end
      alias_method :fill_color=, :fill_color

      def stroke_color(*color)
        return current_stroke_color if color.empty?

        color = process_color(*color)
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
        when String
          return :RGB if /\A\h{6}\z/.match?(color)
        when Array
          return :RGB if color.length == 3
          return :CMYK if color.length == 4
        end
        raise ArgumentError, "Unknown type of color: #{color.inspect}"
      end

      def normalize_color(color)
        case color_type(color)
        when :RGB
          r, g, b = hex2rgb(color)
          [r / 255.0, g / 255.0, b / 255.0]
        when :CMYK
          color.map { _1 / 100.0 }
        end
      end

      def color_to_s(color)
        return PDF::Core.real_params(normalize_color(color)) unless color.is_a?(String)

        PDF_OPERANDS_BY_HEX_COLOR.fetch(color) do
          operands = PDF::Core.real_params(normalize_color(color))
          PDF_OPERANDS_BY_HEX_COLOR[color.dup.freeze] = operands if PDF_OPERANDS_BY_HEX_COLOR.size < HEX_COLORS_CACHED
          operands
        end
      end

      def color_space(color)
        (color_type(color) == :RGB) ? :DeviceRGB : :DeviceCMYK
      end

      def set_color_space(type, color_space)
        return if current_color_space(type) == color_space && !page.in_stamp_stream?

        set_current_color_space(color_space, type)
        raise ArgumentError, "unknown color space: '#{color_space}'" unless COLOR_SPACES.include?(color_space)

        operator = COLOR_SPACE_OPERATOR_BY_TYPE.fetch(type) { raise ArgumentError, "unknown type '#{type}'" }
        add_content("/#{color_space} #{operator}")
      end

      def set_color(type, color, options = {})
        operator = OPERATOR_BY_TYPE.fetch(type) { raise ArgumentError, "unknown type '#{type}'" }
        if options[:pattern]
          set_color_space(type, :Pattern)
          add_content("/#{color} #{operator}")
        else
          set_color_space(type, color_space(color))
          write_color(color_to_s(color), operator)
        end
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
