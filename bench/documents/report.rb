# A 101-page report: embedded TrueType font, a PNG with alpha and a JPEG on every page, justified text.
font_families.update("DejaVuSans" => {normal: "#{DATA_DIRECTORY}/fonts/DejaVuSans.ttf", bold: "#{DATA_DIRECTORY}/fonts/DejaVuSans-Bold.ttf"})
font "DejaVuSans", size: 10
paragraph = "A quarterly report gathers sales figures, charts and summary tables from every region: " \
  "each part counts, from the raw data all the way to the layout of each page. "
50.times do |chapter|
  image "#{DATA_DIRECTORY}/images/dice.png", width: 120, position: :right
  text "Chapter #{chapter + 1}", style: :bold, size: 16
  12.times { text paragraph * 4, align: :justify }
  image "#{DATA_DIRECTORY}/images/stef.jpg", width: 80
  start_new_page
end
