# frozen_string_literal: true

module Prawn
  module Graphics
    include BlendMode
    include Color
    include Dash
    include CapStyle
    include JoinStyle
    include Transparency
    include Transformation
    include Patterns

    # Distance of a cubic Bézier control point approximating a quarter circle of radius 1.
    KAPPA = 4.0 * ((Math.sqrt(2) - 1.0) / 3.0)

    def move_to(*point)
      x, y = map_to_absolute(point)
      add_content("#{PDF::Core.real(x)} #{PDF::Core.real(y)} m")
    end

    def line_to(*point)
      x, y = map_to_absolute(point)
      add_content("#{PDF::Core.real(x)} #{PDF::Core.real(y)} l")
    end

    def curve_to(destination, options = {})
      options[:bounds] || raise(Errors::InvalidGraphicsPath, "Bounding points for bezier curve must be specified as :bounds => [[x1,y1],[x2,y2]]")

      add_content("#{PDF::Core.real_params((options[:bounds] << destination).flat_map { map_to_absolute(_1) })} c")
    end

    def rectangle(point, width, height)
      x, y = map_to_absolute(point)
      add_content("#{PDF::Core.real_params([x, y - height, width, height])} re")
    end

    def rounded_rectangle(point, width, height, radius)
      x, y = point
      rounded_polygon(radius, point, [x + width, y], [x + width, y - height], [x, y - height])
    end

    def line_width=(width)
      graphic_state.line_width = width
      write_line_width
    end

    def line_width(width = nil)
      return graphic_state.line_width unless width

      self.line_width = width
    end

    def line(*points)
      x0, y0, x1, y1 = points.flatten
      move_to(x0, y0)
      line_to(x1, y1)
    end

    def horizontal_line(x1, x2, options = {})
      y1 = options[:at] || (y - bounds.absolute_bottom)
      line(x1, y1, x2, y1)
    end

    def horizontal_rule
      horizontal_line(bounds.left, bounds.right)
    end

    def vertical_line(y1, y2, params)
      line(params[:at], y1, params[:at], y2)
    end

    def curve(origin, destination, options = {})
      move_to(*origin)
      curve_to(destination, options)
    end

    def circle(center, radius)
      ellipse(center, radius, radius)
    end

    def ellipse(point, radius1, radius2 = radius1)
      x, y = point
      l1 = radius1 * KAPPA
      l2 = radius2 * KAPPA
      move_to(x + radius1, y)
      curve_to([x, y + radius2], bounds: [[x + radius1, y + l2], [x + l1, y + radius2]])
      curve_to([x - radius1, y], bounds: [[x - l1, y + radius2], [x - radius1, y + l2]])
      curve_to([x, y - radius2], bounds: [[x - radius1, y - l2], [x - l1, y - radius2]])
      curve_to([x + radius1, y], bounds: [[x + l1, y - radius2], [x + radius1, y - l2]])
      move_to(x, y)
    end

    def polygon(*points)
      move_to(points[0])
      (points.drop(1) << points[0]).each { line_to(*_1) }
      add_content("h")
    end

    def rounded_polygon(radius, *points)
      move_to(point_on_line(radius, points[1], points[0]))
      sides = points.size
      points << points[0] << points[1]
      sides.times { |side| rounded_vertex(radius, points[side], points[side + 1], points[side + 2]) }
      add_content("h")
    end

    def rounded_vertex(radius, *points)
      radial_point1 = point_on_line(radius, points[0], points[1])
      bezier_point1 = point_on_line(radius - (radius * KAPPA), points[0], points[1])
      radial_point2 = point_on_line(radius, points[2], points[1])
      bezier_point2 = point_on_line(radius - (radius * KAPPA), points[2], points[1])
      line_to(radial_point1)
      curve_to(radial_point2, bounds: [bezier_point1, bezier_point2])
    end

    def stroke
      yield if block_given?
      add_content("S")
    end

    def close_and_stroke
      yield if block_given?
      add_content("s")
    end

    def stroke_bounds
      stroke_rectangle(bounds.top_left, bounds.width, bounds.height)
    end

    def stroke_axis(options = {})
      origin = options[:at] || [0, 0]
      options = {
        at: [0, 0], height: bounds.height - origin[1], width: bounds.width - origin[0],
        step_length: 100, negative_axes_length: 20, color: "000000"
      }.merge(options)
      Prawn.verify_options(%i[at width height step_length negative_axes_length color], options)
      x, y = options[:at]

      save_graphics_state do
        fill_color(options[:color])
        stroke_color(options[:color])
        dash(1, space: 4)
        stroke_horizontal_line(x - options[:negative_axes_length], x + options[:width], at: y)
        stroke_vertical_line(y - options[:negative_axes_length], y + options[:height], at: x)
        undash
        fill_circle(options[:at], 1)
        (options[:step_length]..options[:width]).step(options[:step_length]) do |point|
          fill_circle([x + point, y], 1)
          draw_text(point, at: [x + point - 5, y - 10], size: 7)
        end
        (options[:step_length]..options[:height]).step(options[:step_length]) do |point|
          fill_circle([x, y + point], 1)
          draw_text(point, at: [x - 17, y + point - 2], size: 7)
        end
      end
    end

    def fill(options = {})
      yield if block_given?
      add_content((options[:fill_rule] == :even_odd) ? "f*" : "f")
    end

    def fill_and_stroke(options = {})
      yield if block_given?
      add_content((options[:fill_rule] == :even_odd) ? "b*" : "b")
    end

    def close_path
      add_content("h")
    end

    SHAPES = %i[
      line_to curve_to rectangle rounded_rectangle line horizontal_line horizontal_rule vertical_line curve circle_at circle
      ellipse_at ellipse polygon rounded_polygon rounded_vertex
    ].freeze

    %i[fill stroke fill_and_stroke].product(SHAPES).each do |operation, shape|
      define_method(:"#{operation}_#{shape}") do |*arguments|
        public_send(operation) { public_send(shape, *arguments) }
      end
    end

    private

    def write_line_width
      add_content("#{graphic_state.line_width} w")
    end

    # Called with x, y or [x, y] for every point drawn: those two shapes skip the copy flatten makes.
    def map_to_absolute(*point)
      point = point[0] if point.size == 1 && point[0].is_a?(Array)
      x, y = (point.size == 2 && point[0].is_a?(Numeric) && point[1].is_a?(Numeric)) ? point : point.flatten
      [@bounding_box.absolute_left + x, @bounding_box.absolute_bottom + y]
    end

    def map_to_absolute!(point)
      point.replace(map_to_absolute(point))
    end

    def degree_to_rad(angle)
      angle * Math::PI / 180
    end

    def point_on_line(distance_from_end, *points)
      x0, y0, x1, y1 = points.flatten
      length = Math.sqrt(((x1 - x0)**2) + ((y1 - y0)**2))
      ratio = (length - distance_from_end) / length
      [x0 + (ratio * (x1 - x0)), y0 + (ratio * (y1 - y0))]
    end
  end
end
