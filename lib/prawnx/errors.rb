# frozen_string_literal: true

# Errors Prawn raises from PDF::Core keep that name: apps rescue them by it.
module PDF
  module Core
    module Errors
      EmptyGraphicStateStack = Class.new(StandardError)
      FailedObjectConversion = Class.new(StandardError)
      InvalidPageLayout = Class.new(StandardError)
    end
  end
end

module Prawn
  module Errors
    EmptyGraphicStateStack = PDF::Core::Errors::EmptyGraphicStateStack
    FailedObjectConversion = PDF::Core::Errors::FailedObjectConversion
    InvalidPageLayout = PDF::Core::Errors::InvalidPageLayout
    BlockRequired = Class.new(StandardError)
    CannotFit = Class.new(StandardError)
    CannotGroup = Class.new(StandardError)
    IncompatibleStringEncoding = Class.new(StandardError)
    InvalidGraphicsPath = Class.new(StandardError)
    InvalidJoinStyle = Class.new(StandardError)
    InvalidName = Class.new(StandardError)
    InvalidTableSpan = Class.new(StandardError)
    NameTaken = Class.new(StandardError)
    NotOnPage = Class.new(StandardError)
    RequiredOption = Class.new(StandardError)
    UndefinedObjectName = Class.new(StandardError)
    UnknownFont = Class.new(StandardError)
    UnknownOption = Class.new(StandardError)
    UnknownOutlineTitle = Class.new(StandardError)
    UnrecognizedTableContent = Class.new(StandardError)
    UnsupportedImageType = Class.new(StandardError)
  end
end
