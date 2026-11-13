# The catalog of bench/documents, written with Gamba's own API.
document.register_font "DejaVuSans", normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"
document.style :default, font: "DejaVuSans", size: 9
document.footer { |footer, page| footer.text "#{page.number}/#{page.total}", align: :right }
lines = Array.new(1000) { {sku: "SKU#{_1}", description: "Widget, medium size, blue finish, heavy-duty model #{_1}", quantity: "1", price: "$899.00"} }
document.table(lines, columns: {sku: {title: "SKU"}, description: {}, quantity: {title: "Qty"}, price: {}}, header: {weight: :normal}, cell: {padding: 3})
