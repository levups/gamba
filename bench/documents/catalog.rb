# A long catalog: a thousand table rows over many pages, the header repeated on each one.
font_families.update("DejaVuSans" => {normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"})
font "DejaVuSans", size: 9
lines = Array.new(1000) { ["SKU#{it}", "Widget, three-way, walnut finish, heavy-duty model #{it}", "1", "$899.00"] }
table([%w[SKU Description Qty Price], *lines], header: true, width: bounds.width, cell_style: {padding: 3})
number_pages "<page>/<total>", at: [bounds.right - 50, 0], width: 50, align: :right
