# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest"
  gem "railties" # test/rails boots an application on it
  gem "rake"
  gem "rubocop-performance", require: false
  gem "standard", require: false
  gem "vernier"
end

group :development do
  gem "rouge", "5.1.0" # pinned: docs:highlight:check compares its output with the committed pages
end
