# frozen_string_literal: true

# Both faces of one collection, measured one after the other: each must keep its own widths.
collection = "#{CACHE_DIRECTORY}/prawn/data/fonts/DejaVuSans.ttc"
font(collection, font: 0) { text "Résumé", align: :right }
font(collection, font: 1) { text "Résumé", align: :right }
