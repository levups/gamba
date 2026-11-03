# frozen_string_literal: true

module Prawn
  # Mixed into a class, turns it into a document: Prawn's methods are called on an implicit Prawn::Document.
  module View
    def document
      @document ||= Document.new
    end

    def method_missing(method_name, *arguments, **options, &)
      return super unless document.respond_to?(method_name)

      document.public_send(method_name, *arguments, **options, &)
    end

    def respond_to_missing?(method_name, include_all = false)
      document.respond_to?(method_name) || super
    end

    def update(&)
      instance_eval(&)
    end

    def save_as(filename)
      document.render_file(filename)
    end
  end
end
