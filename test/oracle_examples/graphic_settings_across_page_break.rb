# frozen_string_literal: true

# Colours, line width, dash and cap and join styles set before a block whose text flows onto the next page: Prawn
# draws what follows the block in black, with thin solid lines; Gamba draws it as before the block.
fill_color "cc0000"
stroke_color "0000cc"
line_width 4
dash 12, space: 6
cap_style :round
join_style :bevel
save_graphics_state do
  fill_color "009900"
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 60, size: 18
end
text "Red again"
stroke_rectangle [bounds.left, cursor - 10], 200, 60
