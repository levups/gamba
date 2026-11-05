# frozen_string_literal: true

# A blend mode set without a block, then a table that breaks pages, inside a block setting another one: Prawn draws
# the next page in the normal blend mode; Gamba keeps each blend mode until it is changed or its block ends.
fill_color "3366cc"
blend_mode(:Multiply)
save_graphics_state do
  blend_mode(:Darken)
  table(Array.new(60) { |row| ["Row #{row + 1}", "alice@example.com", "Post #{row + 1}"] }, cell_style: {background_color: "ffcc00"})
end
fill_color "ffcc00"
fill_rectangle [bounds.left, cursor], 300, 40
fill_color "3366cc"
fill_rectangle [bounds.left + 100, cursor - 20], 300, 40
