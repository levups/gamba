# A one-page invoice: embedded TrueType font, a JPEG letterhead, a ten-line table.
font_families.update("DejaVuSans" => {normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"})
font "DejaVuSans", size: 9
image "#{DATA_DIRECTORY}/images/letterhead.jpg", width: 200
text "Invoice INV-2026-0001 — Alice Example", style: :bold, size: 14
move_down 10
lines = Array.new(10) { ["SKU#{_1}", "Gadget, deluxe edition, model #{_1} with spare parts toolkit", "2", "$1,299.00", "$2,598.00"] }
table([%w[SKU Description Qty Unit Total], *lines], header: true, width: bounds.width, cell_style: {padding: 3})
