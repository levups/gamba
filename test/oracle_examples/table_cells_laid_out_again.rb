# frozen_string_literal: true

# Cells whose layout, measured while the table is sized, no longer holds when they are drawn.
data = [
  ["Made tall", "Centred vertically, in a row made tall by its neighbour"],
  [{content: "<color rgb='CC0000'>Red</color> and <b>bold</b> inline", inline_format: true}, "A cell wrapped over several lines, because its column is narrow"],
  ["Changed before drawing", "Replaced"]
]
table(data, column_widths: [120, 160], cell_style: {size: 10}) do
  cells[0, 1].valign = :center
  cells[0, 0].height = 60
  before_rendering_page do |page|
    page[2, 1].content = "This text was set by before_rendering_page, after the table was sized, and runs long"
  end
end
move_down 10
table([["Truncated by a fixed height that is far too small for this whole sentence"]], column_widths: [100]) do
  cells[0, 0].height = 22
end
move_down 10
shrunk = make_table([["Laid out in full, then given a height that only fits its first line before drawing"]], column_widths: [100])
shrunk.cells[0, 0].height = 22
shrunk.draw
move_down 10
font_size(14) { table([["Same table, other font size", "measured again"]]) }
move_down 10
table([[{content: "Shrunk to fit a cell its neighbour sizes", overflow: :shrink_to_fit, size: 14}, {content: "Turned", rotate: 30}, "Tall\nneighbour\nof\nfour lines"]], column_widths: [90, 80, 80])
