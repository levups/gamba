# frozen_string_literal: true

require_relative "measurements"

# 10.mm, 2.cm, 1.in…: lengths in PDF points.
class Numeric
  include Prawn::Measurements

  def mm
    mm2pt(self)
  end

  def cm
    cm2pt(self)
  end

  def dm
    dm2pt(self)
  end

  def m
    m2pt(self)
  end

  def in
    in2pt(self)
  end

  def yd
    yd2pt(self)
  end

  def ft
    ft2pt(self)
  end

  def pt
    pt2pt(self)
  end
end
