# frozen_string_literal: true

# Gradients set as the fill and stroke, then text flowing onto the next page inside a block of its own colour: Prawn
# paints the rest in the colour set before the gradients; PrawnX keeps painting with them.
fill_color "336699"
fill_gradient [0, 0], [bounds.width, 0], "ff0000", "0000ff"
stroke_gradient from: [0, 0], to: [0, bounds.height], stops: %w[00aa00 000000]
line_width 6
save_graphics_state do
  fill_color "993399"
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 50, size: 18
end
text "Bob, in the fill gradient", size: 24
stroke_rectangle [bounds.left, cursor - 10], 300, 80
