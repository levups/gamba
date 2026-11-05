# frozen_string_literal: true

# A header stamped on every page, page numbers and a dynamic footer, after a rotated block and a transparent one ran
# over several pages: Prawn draws them inside each block on the page where it began, faded or tilted; Gamba draws
# them the same on every page.
repeat(:all) do
  fill_color "336699"
  fill_rectangle [bounds.left, bounds.top + 20], bounds.width, 14
end
repeat(:all, dynamic: true) { draw_text "Footer #{page_number}", at: [bounds.left, -20] }
rotate(4, origin: [0, 0]) do
  text "Alice was beginning to get very tired of sitting by her sister on the bank. " * 30, size: 14
end
transparent(0.3) do
  text "Bob had nothing to do: once or twice he had peeped into the book his sister was reading. " * 60, size: 14
end
number_pages "<page> / <total>", at: [bounds.right - 60, -20], width: 60, align: :right
