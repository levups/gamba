# frozen_string_literal: true

if Gem.loaded_specs.key?("prawn")
  raise LoadError, "PrawnX replaces the prawn gem, which is in your bundle too: remove prawn (and prawn-table, " \
    "prawn-svg) from your Gemfile"
end

require_relative "prawnx/version"

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

require_relative "prawnx/errors"
require_relative "prawnx/pdf"
require_relative "prawnx/pdf/reference"
require_relative "prawnx/pdf/writer"
require_relative "prawnx/pdf/outline_node"
require_relative "prawnx/page_geometry"
require_relative "prawnx/encoding"
require_relative "prawnx/graphic_state"
require_relative "prawnx/page"
require_relative "prawnx/transformation_stack"
require_relative "prawnx/graphics/color"
require_relative "prawnx/graphics/style"
require_relative "prawnx/graphics/patterns"
require_relative "prawnx/graphics"
require_relative "prawnx/text"
require_relative "prawnx/text/formatted/parser"
require_relative "prawnx/text/formatted/fragment"
require_relative "prawnx/text/formatted/arranger"
require_relative "prawnx/text/formatted/line_wrap"
require_relative "prawnx/text/formatted/wrap"
require_relative "prawnx/text/formatted/box"
require_relative "prawnx/text/box"
require_relative "prawnx/annotations"
require_relative "prawnx/stamp"
require_relative "prawnx/measurements"
require_relative "prawnx/view"
require_relative "prawnx/images"
require_relative "prawnx/images/png_decoder"
require_relative "prawnx/images/image"
require_relative "prawnx/repeater"
require_relative "prawnx/grid"
require_relative "prawnx/outline"
require_relative "prawnx/table"
require_relative "prawnx/table/cells"
require_relative "prawnx/table/cell"
require_relative "prawnx/table/cell/kinds"
require_relative "prawnx/security"
require_relative "prawnx/pdf_a"
require_relative "prawnx/pdf_a/srgb_profile"
require_relative "prawnx/document/internals"
require_relative "prawnx/document/bounding_box"
require_relative "prawnx/document/span"
require_relative "prawnx/document/column_box"
require_relative "prawnx/document"
require_relative "prawnx/font"
require_relative "prawnx/fonts/afm"

# TrueType fonts load on first use: a document of standard fonts never needs them.
module PrawnX
  module TrueType
    autoload :Error, ::File.expand_path("prawnx/true_type/file", __dir__)
    autoload :File, ::File.expand_path("prawnx/true_type/file", __dir__)
    autoload :Subset, ::File.expand_path("prawnx/true_type/subset", __dir__)
    autoload :SimpleSubsets, ::File.expand_path("prawnx/true_type/simple_subsets", __dir__)
    autoload :CffSubset, ::File.expand_path("prawnx/true_type/cff_subset", __dir__)
    autoload :OpenTypeLayout, ::File.expand_path("prawnx/true_type/open_type_layout", __dir__)
  end
end

module Prawn
  module Fonts
    %i[TTF TTC DFont].each { autoload it, ::File.expand_path("prawnx/fonts/ttf", __dir__) }
    autoload :OTF, ::File.expand_path("prawnx/fonts/otf", __dir__)
  end

  class Font
    %i[TTF TTC DFont].each { autoload it, ::File.expand_path("prawnx/fonts/ttf", __dir__) }
  end
end

module PrawnX
  # Loads what PrawnX otherwise loads on first use, SVG support included: call it before a server forks its
  # workers, so they share that memory instead of each loading its own copy.
  def self.eager_load!
    [TrueType::File, TrueType::Subset, Prawn::Fonts::TTF]
    require "prawn-svg"
  end
end

Prawn.image_handler.register(Prawn::Images::JPG)
Prawn.image_handler.register(Prawn::Images::PNG)
