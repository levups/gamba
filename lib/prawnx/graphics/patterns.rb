# frozen_string_literal: true

require "digest/sha1"

module Prawn
  module Graphics
    # Axial and radial gradients, as shading patterns (ISO 32000-1 §8.7.4.5).
    module Patterns
      GradientStop = Data.define(:position, :color)
      Gradient = Data.define(:type, :apply_transformations, :stops, :from, :to, :r1, :r2)
      IDENTITY_MATRIX = [1, 0, 0, 1, 0, 0].freeze

      def fill_gradient(*, **)
        set_gradient(:fill, *, **)
      end

      def stroke_gradient(*, **)
        set_gradient(:stroke, *, **)
      end

      private

      def set_gradient(type, *, **)
        gradient = parse_gradient_arguments(*, **)
        name = "SP#{gradient_registry_key(gradient)}"
        reference = page.resources.dig(:Pattern, name) || ((@gradient_registry ||= {})[name] ||= create_gradient_pattern(gradient))
        write_pattern(type, {name:, reference:})
      end

      def parse_gradient_arguments(*arguments, from: nil, to: nil, r1: nil, r2: nil, stops: nil, apply_transformations: nil)
        case arguments.length
        when 0 then apply_transformations = true if apply_transformations.nil?
        when 4 then from, to, *stops = arguments
        when 6 then from, r1, to, r2, *stops = arguments
        else raise ArgumentError, "Unknown type of gradient: #{arguments.inspect}"
        end
        raise ArgumentError, "At least two stops must be specified" if stops.length < 2

        stops = stops.each_with_index.map do |stop, index|
          if stop.is_a?(Array) || stop.is_a?(Hash)
            position, color = stop
          else
            position = index / (Float(stops.length) - 1)
            color = stop
          end
          raise ArgumentError, "position must be between 0 and 1" unless (0..1).cover?(position)

          GradientStop.new(position, normalize_color(color))
        end
        raise ArgumentError, "The first stop must have a position of 0" if stops.first.position != 0
        raise ArgumentError, "The last stop must have a position of 1" if stops.last.position != 1
        color_types = stops.map { color_type(_1.color) }
        color_types.uniq!
        raise ArgumentError, "All colors must be of the same color space" if color_types.length > 1

        Gradient.new(r1 ? :radial : :axial, apply_transformations, stops, from, to, r1, r2)
      end

      def gradient_registry_key(gradient)
        _x1, _y1, x2, y2, transformation = gradient_coordinates(gradient)
        key = [gradient.type.to_s, transformation, x2, y2, gradient.r1 || -1, gradient.r2 || -1, gradient.stops.length,
          gradient.stops.map { |stop| [stop.position, stop.color] }].flatten
        Digest::SHA1.hexdigest(key.join(","))
      end

      def create_gradient_pattern(gradient)
        if gradient.apply_transformations.nil? && current_transformation_matrix_with_translation(0, 0) != IDENTITY_MATRIX
          warn "Gradients in Prawn 2.x and lower are not correctly positioned when a transformation has been made to the " \
            "document. Pass 'apply_transformations: true' to correctly transform the gradient, or see " \
            "https://github.com/prawnpdf/prawn/wiki/Gradient-Transformations for more information."
        end

        functions = gradient.stops.each_cons(2).map do |first, second|
          ref!(FunctionType: 2, Domain: [0.0, 1.0], C0: first.color, C1: second.color, N: 1.0)
        end
        function =
          if functions.length == 1
            functions.first
          else
            ref!(FunctionType: 3, Domain: [0.0, 1.0], Functions: functions, Bounds: gradient.stops[1..-2].map(&:position),
              Encode: [0.0, 1.0] * functions.length)
          end

        x1, y1, x2, y2, transformation = gradient_coordinates(gradient)
        coordinates = (gradient.type == :axial) ? [0, 0, x2 - x1, y2 - y1] : [0, 0, gradient.r1, x2 - x1, y2 - y1, gradient.r2]
        shading = ref!(ShadingType: (gradient.type == :axial) ? 2 : 3, ColorSpace: color_space(gradient.stops.first.color),
          Coords: coordinates, Function: function, Extend: [true, true])
        ref!(PatternType: 2, Shading: shading, Matrix: transformation)
      end

      def gradient_coordinates(gradient)
        x1, y1 = map_to_absolute(gradient.from)
        x2, y2 = map_to_absolute(gradient.to)
        transformation = gradient.apply_transformations ? current_transformation_matrix_with_translation(x1, y1) : [1, 0, 0, 1, x1, y1]
        [x1, y1, x2, y2, transformation]
      end
    end
  end
end
