# frozen_string_literal: true

# A transparent block whose text flows onto a page that exists already: Prawn draws it opaque there, Gamba keeps
# the opacity for what the block adds, not for what the page drew before, nor for the page numbers drawn after.
start_new_page
fill_color "336699"
fill_rectangle [bounds.left, bounds.top], bounds.width, 120
fill_color "000000"
go_to_page 1
move_down 560
transparent(0.3) do
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 30, size: 18
end
text "Opaque again"
number_pages "<page> / <total>", at: [bounds.right - 60, -20], width: 60, align: :right
