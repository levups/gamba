# frozen_string_literal: true

# Rows that hold no cell, such as columns chosen by a user who chose none: Gamba draws nothing there.
text "Before the table"
table([[]])
text "After the table"
