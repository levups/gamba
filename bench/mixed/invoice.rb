# The invoice of bench/documents, its table moved to one block of Gamba's own API: the middle step of a migration.
font_families.update("DejaVuSans" => {normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"})
font "DejaVuSans", size: 9
image "#{DATA_DIRECTORY}/images/letterhead.jpg", width: 200
text "Invoice INV-2026-0001 — Alice Example", style: :bold, size: 14
move_down 10
lines = Array.new(10) { {sku: "SKU#{_1}", description: "Gadget, deluxe edition, model #{_1} with spare parts toolkit", quantity: "2", unit: "$1,299.00", total: "$2,598.00"} }
gamba do |document|
  document.table(lines, columns: {sku: {title: "SKU"}, description: {}, quantity: {title: "Qty"}, unit: {}, total: {}}, header: {weight: :normal}, cell: {padding: 3})
end
