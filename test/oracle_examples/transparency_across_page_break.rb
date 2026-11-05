# frozen_string_literal: true

# A transparent block whose text flows onto the next page: Prawn draws that page opaque, Gamba keeps the opacity.
transparent(0.5, 0.25) do
  fill_color "cc0000"
  stroke_color "0000cc"
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 60, size: 18
  line_width 6
  stroke_rectangle [bounds.left, cursor], 200, 60
end
text "Opaque again"
