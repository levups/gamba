# The report of bench/documents, written with Gamba's own API.
document.register_font "DejaVuSans", normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"
document.style :default, font: "DejaVuSans", size: 10
document.style :chapter, weight: :bold, size: 16, keep_with_next: true
paragraph = "A quarterly report gathers sales figures, charts and summary tables from every region: " \
  "each part counts, from the raw data all the way to the layout of each page. "
50.times do |chapter|
  document.image "#{DATA_DIRECTORY}/images/dice.png", width: 120, align: :right
  document.text "Chapter #{chapter + 1}", style: :chapter
  12.times { document.text paragraph * 4, align: :justify }
  document.image "#{DATA_DIRECTORY}/images/stef.jpg", width: 80
  document.page_break
end
