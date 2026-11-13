# The invoice of bench/documents, written with Gamba's own API.
document.register_font "DejaVuSans", normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"
document.style :default, font: "DejaVuSans", size: 9
document.image "#{DATA_DIRECTORY}/images/letterhead.jpg", width: 200
document.text "Invoice INV-2026-0001 — Alice Example", weight: :bold, size: 14
lines = Array.new(10) { {sku: "SKU#{_1}", description: "Gadget, deluxe edition, model #{_1} with spare parts toolkit", quantity: "2", unit: "$1,299.00", total: "$2,598.00"} }
document.stack(padding: [10, 0, 0, 0]) do |stack|
  stack.table(lines, columns: {sku: {title: "SKU"}, description: {}, quantity: {title: "Qty"}, unit: {}, total: {}}, header: {weight: :normal}, cell: {padding: 3})
end
