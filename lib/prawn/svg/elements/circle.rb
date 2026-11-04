class Prawn::SVG::Elements::Circle < Prawn::SVG::Elements::Base
  def parse
    require_attributes "r"

    @x = x(attributes["cx"] || "0")
    @y = y(attributes["cy"] || "0")
    @r = pixels(attributes["r"])

    require_positive_value @r
  end

  def apply
    add_call "circle", [@x, @y], @r
  end

  def bounding_box
    [@x - @r, @y + @r, @x + @r, @y - @r]
  end
end
