# frozen_string_literal: true

# A transparent block whose table flows onto the next page, inside character spacing and rise blocks: the new page and
# what follows the transparent block keep both until their blocks end.
character_spacing(2) do
  rise(3) do
    transparent(0.6) do
      table(Array.new(50) { |row| ["Row #{row + 1}", "alice@example.com", "Post #{row + 1}"] })
    end
    text "Still spaced and raised"
  end
end
text "Plain again"
