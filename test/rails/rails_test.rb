# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "fileutils"
require "tmpdir"
require "logger"
require "rails"
require "action_controller/railtie"
require "gamba"
require_relative "../support/oracle"

CORPUS_MISSING_MESSAGE = "corpus/cache is empty: run `bundle exec rake corpus:fetch`"

# A Rails application with Gamba in its bundle: controllers render PDFs, `.pdf.rb` templates draw them with the
# view's helpers, and Gamba loads before the server forks.
class RailsTest < Minitest::Test
  VIEWS = Dir.mktmpdir("gamba-views")
  TEMPLATES = File.join(VIEWS, "rails_test/documents").tap { FileUtils.mkdir_p(_1) }
  File.write(File.join(TEMPLATES, "show.pdf.rb"), <<~RUBY)
    document.text t("greeting", name: "Alice")
    document.text number_to_currency(1234.5, unit: "EUR ", format: "%u%n")
  RUBY
  File.write(File.join(TEMPLATES, "prawn.pdf.rb"), <<~RUBY)
    Prawn::Document.new(page_size: "A4") { text "Prawn in a template" }
  RUBY

  # An application's own document class: Gamba asks it for to_pdf.
  Invoice = Struct.new(:number) do
    def to_pdf
      Gamba.document { |document| document.text "Invoice #{number}" }.to_s
    end
  end

  # What an Active Storage attachment answers.
  Attachment = Struct.new(:bytes) do
    def download
      bytes
    end
  end

  class Application < Rails::Application
    config.root = VIEWS
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "0" * 64
    config.hosts.clear
    config.i18n.backend = I18n::Backend::Simple.new
  end

  class DocumentsController < ActionController::Base
    prepend_view_path VIEWS

    def native
      render pdf: Gamba.document { |document| document.text "Hello Alice" }, filename: "Facture été 2026.pdf"
    end

    def prawn
      render pdf: Prawn::Document.new { text "Hello from Prawn" }, disposition: :attachment
    end

    def invoice
      render pdf: Invoice.new("INV-2026-0001")
    end

    def show
      render "show", formats: :pdf
    end

    def template_document
      render "prawn", formats: :pdf
    end
  end

  Application.initialize!
  Application.routes.draw do
    %w[native prawn invoice show template_document].each { |action| get "documents/#{action}", to: "rails_test/documents##{action}" }
  end
  I18n.backend.store_translations(:en, greeting: "Hello %{name}")

  def test_a_controller_renders_a_document_inline_with_its_filename_encoded
    status, headers, body = request("native")

    assert_equal 200, status
    assert_equal "application/pdf", headers["content-type"]
    assert_equal %(inline; filename="Facture ete 2026.pdf"; filename*=UTF-8''Facture%20%C3%A9t%C3%A9%202026.pdf), headers["content-disposition"]
    assert_equal ["Hello Alice"], lines(body)
  end

  def test_prawn_documents_and_objects_answering_to_pdf_render_too
    _status, headers, body = request("prawn")

    assert_equal "attachment", headers["content-disposition"]
    assert_equal ["Hello from Prawn"], lines(body)
    assert_equal ["Invoice INV-2026-0001"], lines(request("invoice").last)
    assert_raises(ArgumentError) { Gamba::Railtie.pdf(Object.new) }
  end

  def test_a_template_draws_on_a_document_with_the_view_helpers
    status, headers, body = request("show")

    assert_equal 200, status
    assert_equal "application/pdf", headers["content-type"]
    assert_equal ["Hello Alice", "EUR 1,234.50"], lines(body)
  end

  def test_a_template_that_ends_with_its_own_document_renders_that_one
    assert_equal ["Prawn in a template"], lines(request("template_document").last)
  end

  def test_active_storage_attachments_are_images_and_pdf_pages
    path = File.join(Oracle::ROOT, "corpus/cache/prawn/data/images/dice.png")
    skip CORPUS_MISSING_MESSAGE unless File.exist?(path)

    png = File.binread(path)
    letterhead = Attachment.new(Prawn::Document.new { text "Letterhead" }.render)
    document = Prawn::Document.new do
      image Attachment.new(png), width: 50
      pdf_page letterhead, width: 100
    end

    assert_includes lines(document.render), "Letterhead"
  end

  def test_gamba_loads_before_the_server_forks_when_rails_eager_loads
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", <<~RUBY)
      require "logger"
      require "rails"
      require "action_controller/railtie"
      require "gamba"
      class EagerApplication < Rails::Application
        config.root = Dir.pwd
        config.eager_load = true
        config.logger = Logger.new(nil)
        config.secret_key_base = "0" * 64
      end
      EagerApplication.initialize!
      print Gamba::Barcodes.autoload?(:QRCode).inspect, " ", Gamba.autoload?(:ImportedPage).inspect
    RUBY

    assert status.success?, output
    assert_equal "nil nil", output.lines.last
  end

  def test_without_rails_gamba_defines_nothing_of_it
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", 'require "gamba"; print defined?(Rails).inspect, " ", defined?(ActiveSupport).inspect, " ", Gamba.const_defined?(:Railtie, false)')

    assert status.success?, output
    assert_equal "nil nil false", output
  end

  private

  def request(action)
    status, headers, body = Application.call(Rack::MockRequest.env_for("/documents/#{action}"))
    [status, headers, body.each.to_a.join]
  end

  def lines(pdf)
    Tempfile.create(["rails", ".pdf"]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      Oracle.text_layout(file.path).flat_map { |page| page.glyphs.group_by(&:last).sort.map { |_y, glyphs| glyphs.map(&:first).join } }
    end
  end
end
