# frozen_string_literal: true

module Gamba
  # What a Rails application gets once Gamba is in its bundle: `render pdf:` in controllers, `.pdf.rb` templates,
  # and Gamba loaded before the server forks. Defined only when Rails is.
  class Railtie < ::Rails::Railtie
    # The bytes of what a controller renders or a template ends with: a Gamba::Document, a Prawn::Document, an
    # object answering to_pdf (a document class of the application), or the bytes themselves.
    def self.pdf(document)
      if document.respond_to?(:to_pdf) then document.to_pdf
      elsif document.is_a?(Gamba::Document) then document.to_s
      elsif document.respond_to?(:render) then document.render
      elsif document.is_a?(String) then document
      else raise ArgumentError, "render pdf: takes a Gamba::Document, a Prawn::Document, an object answering to_pdf or a PDF's bytes, not #{document.class}"
      end.b
    end

    # A `.pdf.rb` template: its code runs in the view, helpers and translations at hand, with `document`, a
    # Gamba::Document; Prawn's API is at document.prawn. A template that ends with a document of its own (Gamba's
    # or Prawn's) renders that one instead. A PDF is bytes, not text: the response loses the charset Rails adds.
    module TemplateHandler
      def self.call(template, source)
        <<~RUBY
          document = ::Gamba::Document.new
          result = begin
            #{source}
          end
          if respond_to?(:response) && response
            response.content_type = Mime[:pdf].to_s
            response.charset = false
          end
          ::Gamba::Railtie.pdf(result.is_a?(::Gamba::Document) || result.is_a?(::Prawn::Document) ? result : document)
        RUBY
      end
    end

    # Before the server forks its workers, so they share what Gamba loads instead of each loading its own.
    config.before_eager_load { Gamba.eager_load! }

    initializer "gamba.renderer" do
      ActiveSupport.on_load(:action_controller) do
        ActionController::Renderers.add(:pdf) do |document, options|
          send_data Gamba::Railtie.pdf(document), {type: Mime[:pdf], disposition: "inline"}.merge(options.slice(:filename, :disposition, :status))
        end
      end
    end

    initializer "gamba.template_handler" do
      ActiveSupport.on_load(:action_view) { ActionView::Template.register_template_handler(:rb, Gamba::Railtie::TemplateHandler) }
    end
  end
end
