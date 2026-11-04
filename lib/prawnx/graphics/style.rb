# frozen_string_literal: true

module Prawn
  module Graphics
    module Dash
      def dash(length = nil, options = {})
        return current_dash_state if length.nil?

        length = Array(length)
        raise ArgumentError, "Zero length dashes are invalid. Call #undash to disable dashes." if length.all?(&:zero?)
        raise ArgumentError, "Negative numbers are not allowed for dash lengths." if length.any?(&:negative?)

        length = length.first if length.length == 1
        self.current_dash_state = {dash: length, space: length.is_a?(Array) ? nil : options[:space] || length, phase: options[:phase] || 0}
        write_stroke_dash
      end
      alias_method :dash=, :dash

      def undash
        self.current_dash_state = PDF::Core::GraphicState::UNDASHED.dup
        write_stroke_dash
      end

      def dashed?
        current_dash_state != PDF::Core::GraphicState::UNDASHED
      end

      private

      def write_stroke_dash
        add_content(graphic_state.dash_setting)
      end

      def current_dash_state=(dash_options)
        graphic_state.dash = dash_options
      end

      def current_dash_state
        graphic_state.dash
      end
    end

    module CapStyle
      CAP_STYLES = {butt: 0, round: 1, projecting_square: 2}.freeze

      def cap_style(style = nil)
        return graphic_state.cap_style || :butt if style.nil?

        graphic_state.cap_style = style
        write_stroke_cap_style
      end
      alias_method :cap_style=, :cap_style

      private

      def write_stroke_cap_style
        add_content("#{CAP_STYLES[graphic_state.cap_style]} J")
      end
    end

    module JoinStyle
      JOIN_STYLES = {miter: 0, round: 1, bevel: 2}.freeze

      def join_style(style = nil)
        return graphic_state.join_style || :miter if style.nil?

        graphic_state.join_style = style
        unless JOIN_STYLES.key?(style)
          raise Errors::InvalidJoinStyle, "#{style} is not a recognized join style. Valid styles are #{JOIN_STYLES.keys.join(", ")}"
        end

        write_stroke_join_style
      end
      alias_method :join_style=, :join_style

      private

      def write_stroke_join_style
        add_content("#{JOIN_STYLES[graphic_state.join_style]} j")
      end
    end

    module Transparency
      def transparent(opacity, stroke_opacity = opacity)
        min_version(1.4)
        opacity = opacity.clamp(0.0, 1.0)
        stroke_opacity = stroke_opacity.clamp(0.0, 1.0)
        @opacity_dictionary_registry ||= {}
        ext_gstate = @opacity_dictionary_registry["#{opacity}_#{stroke_opacity}"] ||=
          {name: "Tr#{@opacity_dictionary_registry.length + 1}", reference: ref!(Type: :ExtGState, CA: stroke_opacity, ca: opacity)}
        ext_gstate_block(ext_gstate) { yield }
      end
    end

    module BlendMode
      def blend_mode(blend_mode = :Normal)
        min_version(1.4)
        ext_gstate = blend_mode_ext_gstate(blend_mode)
        return ext_gstate_block(ext_gstate) { yield } if block_given?

        write_ext_gstate(ext_gstate)
        nil
      end

      private

      def blend_mode_ext_gstate(blend_mode)
        @blend_mode_dictionary_registry ||= {}
        name = "BM#{Array(blend_mode).join}"
        @blend_mode_dictionary_registry[name] ||= {name:, reference: ref!(Type: :ExtGState, BM: blend_mode)}
      end
    end

    module Transformation
      def rotate(angle, options = {}, &block)
        Prawn.verify_options(:origin, options)
        radians = degree_to_rad(angle)
        cos = Math.cos(radians)
        sin = Math.sin(radians)
        return transformation_matrix(cos, sin, -sin, cos, 0, 0, &block) if options[:origin].nil?
        raise Errors::BlockRequired unless block

        x = options[:origin][0] + bounds.absolute_left
        y = options[:origin][1] + bounds.absolute_bottom
        translate(x - ((x * cos) - (y * sin)), y - ((x * sin) + (y * cos))) do
          transformation_matrix(cos, sin, -sin, cos, 0, 0, &block)
        end
      end

      def translate(x, y, &)
        transformation_matrix(1, 0, 0, 1, x, y, &)
      end

      def scale(factor, options = {}, &block)
        Prawn.verify_options(:origin, options)
        return transformation_matrix(factor, 0, 0, factor, 0, 0, &block) if options[:origin].nil?
        raise Errors::BlockRequired unless block

        x = options[:origin][0] + bounds.absolute_left
        y = options[:origin][1] + bounds.absolute_bottom
        translate(x - (factor * x), y - (factor * y)) do
          transformation_matrix(factor, 0, 0, factor, 0, 0, &block)
        end
      end

      def transformation_matrix(*matrix)
        raise ArgumentError, "Transformation matrix must have exacty 6 elements" if matrix.length != 6

        save_graphics_state if block_given?
        add_to_transformation_stack(*matrix)
        add_content("#{PDF::Core.real_params(matrix)} cm")
        return unless block_given?

        yield
        restore_graphics_state
      end
    end
  end
end
