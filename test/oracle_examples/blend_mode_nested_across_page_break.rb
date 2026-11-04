# frozen_string_literal: true

# A blend_mode block inside a transparent one around a table that breaks pages: on the next page each block keeps its
# opacity or blend mode until it ends, and what follows each block has the colour set before it.
fill_color "993399"
transparent(0.6) do
  fill_color "336699"
  blend_mode(:Multiply) do
    table(Array.new(60) { |row| ["Row #{row + 1}", "alice@example.com", "Post #{row + 1}"] }, cell_style: {background_color: "ffcc00"})
  end
  fill_rectangle [bounds.left, cursor], 300, 40
end
text "Opaque, in the colour set first"
