# frozen_string_literal: true

if Gem.loaded_specs.key?("prawn")
  raise LoadError, "Gamba replaces the prawn gem, which is in your bundle too: remove prawn (and prawn-table, " \
    "prawn-svg) from your Gemfile"
end

require_relative "gamba/version"

module Prawn
  BASEDIR = File.expand_path("..", __dir__)
  DATADIR = File.join(BASEDIR, "data")
  FLOAT_PRECISION = 1.0e-9

  class << self
    attr_accessor :debug

    def verify_options(accepted, actual)
      return unless debug || $DEBUG

      unknown = actual.keys - Array(accepted)
      raise Errors::UnknownOption, "\nDetected unknown option(s): #{unknown.inspect}\nAccepted options are: #{Array(accepted).inspect}" unless unknown.empty?

      yield if block_given?
    end
  end
end

require_relative "gamba/errors"
require_relative "gamba/pdf"
require_relative "gamba/pdf/reference"
require_relative "gamba/pdf/writer"
require_relative "gamba/pdf/outline_node"
require_relative "gamba/page_geometry"
require_relative "gamba/encoding"
require_relative "gamba/graphic_state"
require_relative "gamba/page"
require_relative "gamba/transformation_stack"
require_relative "gamba/graphics/color"
require_relative "gamba/graphics/style"
require_relative "gamba/graphics/patterns"
require_relative "gamba/graphics"
require_relative "gamba/text"
require_relative "gamba/text/formatted/parser"
require_relative "gamba/text/formatted/fragment"
require_relative "gamba/text/formatted/arranger"
require_relative "gamba/text/formatted/line_wrap"
require_relative "gamba/text/formatted/wrap"
require_relative "gamba/text/formatted/box"
require_relative "gamba/text/box"
require_relative "gamba/annotations"
require_relative "gamba/stamp"
require_relative "gamba/measurements"
require_relative "gamba/view"
require_relative "gamba/images"
require_relative "gamba/images/png_decoder"
require_relative "gamba/images/image"
require_relative "gamba/repeater"
require_relative "gamba/grid"
require_relative "gamba/outline"
require_relative "gamba/table"
require_relative "gamba/table/cells"
require_relative "gamba/table/cell"
require_relative "gamba/table/cell/kinds"
require_relative "gamba/security"
require_relative "gamba/pdf_a"
require_relative "gamba/pdf_a/srgb_profile"
require_relative "gamba/document/internals"
require_relative "gamba/document/bounding_box"
require_relative "gamba/document/span"
require_relative "gamba/document/column_box"
require_relative "gamba/document"
require_relative "gamba/font"
require_relative "gamba/fonts/afm"

# TrueType fonts load on first use: a document of standard fonts never needs them.
module Gamba
  module TrueType
    autoload :Error, ::File.expand_path("gamba/true_type/file", __dir__)
    autoload :File, ::File.expand_path("gamba/true_type/file", __dir__)
    autoload :Subset, ::File.expand_path("gamba/true_type/subset", __dir__)
    autoload :SimpleSubsets, ::File.expand_path("gamba/true_type/simple_subsets", __dir__)
    autoload :CffSubset, ::File.expand_path("gamba/true_type/cff_subset", __dir__)
    autoload :OpenTypeLayout, ::File.expand_path("gamba/true_type/open_type_layout", __dir__)
  end
end

module Prawn
  module Fonts
    %i[TTF TTC DFont].each { autoload _1, ::File.expand_path("gamba/fonts/ttf", __dir__) }
    autoload :OTF, ::File.expand_path("gamba/fonts/otf", __dir__)
  end

  class Font
    %i[TTF TTC DFont].each { autoload _1, ::File.expand_path("gamba/fonts/ttf", __dir__) }
  end
end

module Gamba
  autoload :Combine, ::File.expand_path("gamba/combine", __dir__)
  autoload :Copier, ::File.expand_path("gamba/copier", __dir__)
  autoload :ImportedPage, ::File.expand_path("gamba/imported_page", __dir__)
  autoload :PageBoxes, ::File.expand_path("gamba/page_boxes", __dir__)
  autoload :Document, ::File.expand_path("gamba/native/document", __dir__)
  autoload :Layout, ::File.expand_path("gamba/native/layout", __dir__)

  # A document written with Gamba's own API: Gamba.document(page_size: "A4") { |document| document.text "Hello" }.
  # See Gamba::Document::OPTIONS for the options; Prawn's API stays reachable through Gamba::Document#prawn.
  def self.document(**options)
    document = Document.new(**options)
    yield document if block_given?
    document
  end

  # The pages of other PDF files, one after the other in a new one:
  # Gamba.combine([label, label], page_size: [288, 432]). See Gamba::Combine#initialize for the options.
  def self.combine(sources, page_size: nil, orientation: nil)
    Combine.new(page_size:, orientation:).call(sources)
  end

  # Loads what Gamba otherwise loads on first use, SVG support included: call it before a server forks its
  # workers, so they share that memory instead of each loading its own copy.
  def self.eager_load!
    [TrueType::File, TrueType::Subset, Prawn::Fonts::TTF, Combine, ImportedPage, PDF::Core::Reader, Document]
    require "prawn-svg"
  end
end

module PDF
  module Core
    autoload :Reader, ::File.expand_path("gamba/pdf/reader", __dir__)
    autoload :Decryption, ::File.expand_path("gamba/pdf/decryption", __dir__)
  end
end

Prawn.image_handler.register(Prawn::Images::JPG)
Prawn.image_handler.register(Prawn::Images::PNG)
