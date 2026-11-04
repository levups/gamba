# frozen_string_literal: true

# Nested blocks around a table that breaks pages, with a header drawn on each new page: on the next page the header
# stays opaque, each block keeps its opacity until it ends, and what follows them is opaque again.
on_page_create { text "Header", align: :right }
transparent(0.8) do
  fill_color "336699"
  save_graphics_state do
    transparent(0.4) do
      table(Array.new(60) { |row| ["Row #{row + 1}", "alice@example.com", "Post #{row + 1}"] }, cell_style: {background_color: "ffcc00"})
    end
    text "Inside the outer block"
  end
  fill_rectangle [bounds.left, cursor], 300, 40
end
text "Opaque again"
