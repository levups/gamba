# frozen_string_literal: true

# Colours, line settings, a blend mode and a gradient set before text flowing onto a page that exists already, with
# settings of its own: Prawn draws there with that page's settings, PrawnX with the ones in effect, as on a new page,
# and the page numbers drawn after with the settings each page ends on.
start_new_page
fill_color "336699"
fill_rectangle [bounds.left, bounds.top], bounds.width, 120
line_width 6
stroke_horizontal_line bounds.left, bounds.right, at: bounds.top - 140
go_to_page 1
move_down 560
fill_color "cc0000"
stroke_gradient [0, 0], [bounds.width, 0], "009900", "0000ff"
line_width 3
dash 8
cap_style :round
blend_mode(:Multiply)
text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 30, size: 18
stroke_horizontal_rule
number_pages "<page> / <total>", at: [bounds.right - 60, -20], width: 60, align: :right
