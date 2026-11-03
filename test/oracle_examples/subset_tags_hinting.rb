# frozen_string_literal: true

# Found by the fuzz: MuPDF hints these bold glyphs differently under Prawn's invalid subset tags.
font_families.update("DejaVu" => {normal: "#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans.ttf", bold: "#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans-Bold.ttf"})
font "DejaVu"
text_box "cliché fl : To office Ta A commas returns fi VAT region points widget report » delivery crème — crème don't widget commas sales widget fl returns résumé » summary", at: [153, cursor], width: 291, height: 76, overflow: :truncate, valign: :bottom, size: 15, align: :justify, style: :bold
formatted_text [{text: "café lumens office ", styles: [:bold]}], align: :justify
