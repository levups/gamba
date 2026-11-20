# frozen_string_literal: true

# How bench/run.rb renders a document of bench/native, shared with the test that checks the tagged ones pass PDF/UA.
module NativeBench
  # Tagged for PDF/UA: the structure tree and its marked content, the language, the title and the XMP metadata.
  STANDARDS = {"pdf_ua" => {pdf: :ua, lang: "en"}}.freeze
  # Prawn's fonts and images, which the documents draw.
  DATA_DIRECTORY = File.expand_path("../corpus/cache/prawn/data", __dir__)

  def self.options(path, standard)
    standard ? {**STANDARDS.fetch(standard), info: {Title: File.basename(path, ".rb").capitalize}} : {}
  end

  # Gamba's own API compresses unasked.
  def self.render(body, path, standard = nil)
    Gamba.document(**options(path, standard)) { |document| write(document, body, path) }.to_s
  end

  # The document sees `document`, `body`, `path` and this module, not the script or the test rendering it.
  def self.write(document, body, path)
    eval(body, binding, path) # rubocop:disable Security/Eval
  end
end
