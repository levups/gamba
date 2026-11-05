# frozen_string_literal: true

# Nested transparent and blend_mode blocks whose text flows onto a page that exists, then onto a new one: Prawn
# draws the existing page opaque and in the normal blend mode, Gamba keeps both, in order, on each page.
start_new_page
fill_color "ffcc00"
fill_rectangle [bounds.left, bounds.top], bounds.width, bounds.height
fill_color "000000"
go_to_page 1
move_down 400
transparent(0.6) do
  blend_mode(:Multiply) do
    text "Bob had nothing to do: once or twice he had peeped into the book his sister was reading. " * 60, size: 18
  end
  text "Faded, normal blend mode"
end
text "Opaque again"
