# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"
require "rexml/document"
require "tempfile"

# Gamba::Invoice computes an invoice's totals with EN 16931's rounding and writes its Cross Industry Invoice XML,
# which Mustang, the Factur-X validator, checks against the schema and the EN 16931 rules when it is installed.
class InvoiceTest < Minitest::Test
  MUSTANG_JAR = ENV.fetch("MUSTANG_JAR", File.expand_path("~/.cache/gamba-tools/Mustang-CLI.jar"))
  JAVA = ENV.fetch("JAVA", ["/opt/homebrew/opt/openjdk/bin/java", "java"].find { system(_1, "-version", err: File::NULL, out: File::NULL) })
  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")
  NAMESPACES = Gamba::Invoice::CrossIndustryInvoice::NAMESPACES

  SELLER = {
    name: "Example Seller Ltd", legal_id: {id: "123456789", scheme: "0002"}, vat: "FR32123456789",
    address: {lines: ["1 Example Street"], postcode: "75001", city: "Paris", country: "FR"},
    electronic_address: {id: "123456789", scheme: "0225"}
  }.freeze
  BUYER = {
    name: "Example Buyer Inc", address: {lines: "2 Example Avenue", postcode: "69001", city: "Lyon", country: "FR"},
    electronic_address: {id: "987654321", scheme: "0225"}
  }.freeze
  FRENCH_NOTES = [
    {text: "Late payment: a fixed compensation of 40 € for recovery costs.", subject: "PMT"},
    {text: "Late payment penalties: three times the legal interest rate.", subject: "PMD"},
    {text: "No discount for early payment.", subject: "AAB"}
  ].freeze

  def test_the_xml_of_a_simple_invoice_is_the_validated_fixture
    expected = File.read(File.join(__dir__, "fixtures/factur_x_en16931.xml"), encoding: Encoding::UTF_8)

    assert_equal expected, simple_invoice.to_xml
  end

  def test_totals_follow_en16931_with_allowances_charges_and_several_rates
    invoice = mixed_invoice

    assert_equal ["39.21", "134.85", "71.75"], invoice.lines.map { format("%.2f", _1.net_amount) }
    assert_equal Rational("245.81"), invoice.line_total
    assert_equal Rational("10.00"), invoice.allowance_total
    assert_equal Rational("12.50"), invoice.charge_total
    assert_equal Rational("248.31"), invoice.tax_basis_total
    assert_equal [[:standard, 20r, Rational("41.71"), Rational("8.34")], [:standard, 10r, Rational("134.85"), Rational("13.49")], [:standard, Rational("5.5"), Rational("71.75"), Rational("3.95")]],
      invoice.tax_breakdown.map { [_1.vat_category, _1.vat_rate, _1.basis, _1.amount] }
    assert_equal Rational("25.78"), invoice.tax_total
    assert_equal Rational("274.09"), invoice.grand_total
    assert_equal Rational("174.09"), invoice.due
  end

  def test_amounts_round_half_up_to_the_cent
    invoice = Gamba::Invoice.new(number: "1", issued_on: Date.new(2026, 11, 1), seller: SELLER, buyer: BUYER, due_on: Date.new(2026, 12, 1),
      lines: [{name: "Post", quantity: 3, unit_price: "0.125", vat_rate: 20}, {name: "Post", quantity: 1, unit_price: "0.025", vat_rate: 20}])

    assert_equal [Rational("0.38"), Rational("0.03")], invoice.lines.map(&:net_amount)
    assert_equal Rational("0.08"), invoice.tax_total
  end

  def test_the_xml_holds_what_the_invoice_computes
    xml = REXML::Document.new(mixed_invoice.to_xml)

    assert_equal "INV-2026-0002", text(xml, "//rsm:ExchangedDocument/ram:ID")
    assert_equal %w[39.21 134.85 71.75], texts(xml, "//ram:SpecifiedTradeSettlementLineMonetarySummation/ram:LineTotalAmount")
    assert_equal %w[8.34 13.49 3.95], texts(xml, "//ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:CalculatedAmount")
    assert_equal %w[20.00 10.00 5.50], texts(xml, "//ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:RateApplicablePercent")
    assert_equal "1.5", text(xml, "//ram:IncludedSupplyChainTradeLineItem[2]//ram:BilledQuantity")
    assert_equal "89.90", text(xml, "//ram:IncludedSupplyChainTradeLineItem[2]//ram:ChargeAmount")
    assert_equal "FR7630006000011234567890189", text(xml, "//ram:IBANID")
    assert_equal "100.00", text(xml, "//ram:TotalPrepaidAmount")
    assert_equal "174.09", text(xml, "//ram:DuePayableAmount")
  end

  def test_text_is_escaped
    invoice = simple_invoice.with(number: "A&B <1>")

    assert_equal "A&B <1>", text(REXML::Document.new(invoice.to_xml), "//rsm:ExchangedDocument/ram:ID")
  end

  def test_each_invoice_passes_mustang
    skip "Mustang or Java is not installed" unless JAVA && File.exist?(MUSTANG_JAR)
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    {simple: simple_invoice, mixed: mixed_invoice, exempt: exempt_invoice, reverse_charge: reverse_charge_invoice, credit_note: credit_note}.each do |name, invoice|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "#{name}.pdf")
        Gamba.document(pdf_a: true, info: {Title: "Invoice #{invoice.number}"}) do |document|
          document.style :default, font: FONT
          document.text "Invoice #{invoice.number}"
          document.factur_x invoice
        end.write(path)
        report, = Open3.capture2e(JAVA, "-jar", MUSTANG_JAR, "--action", "validate", "--source", path, "--no-notices")
        summary = report[/Parsed PDF:.*/]

        assert_match(/Parsed PDF:valid XML:valid/, summary, "#{name}: #{report}")
        assert_match(/Errors:\[\]/, summary, "#{name}: #{report}")
      end
    end
  end

  def test_an_invoice_and_its_xml_embed_the_same_attachment
    xml = mixed_invoice.to_xml
    attachments = [mixed_invoice, xml].map do |invoice|
      document = Prawn::Document.new(pdf_a: true)
      document.factur_x invoice
      Tempfile.create(%w[invoice .pdf]) do |file|
        file.binmode
        file.write(document.render)
        file.close
        Open3.capture2("qpdf", "--show-attachment=factur-x.xml", file.path).first
      end
    end

    assert_equal [xml.b, xml.b], attachments.map(&:b)
  end

  def test_only_the_en16931_profile_is_written_so_far
    error = assert_raises(ArgumentError) { Prawn::Document.new(pdf_a: true).factur_x(simple_invoice, profile: :basic) }

    assert_match(/give the XML of :basic as a String/, error.message)
  end

  def test_amounts_are_never_floats
    error = assert_raises(ArgumentError) { simple_invoice.lines.first.with(unit_price: 9.99) }
    assert_match(/Float/, error.message)

    assert_raises(ArgumentError) { invoice(lines: [{name: "Post", quantity: 1, unit_price: "9,99", vat_rate: 20}]) }
  end

  def test_what_is_missing_or_unknown_raises
    assert_raises(ArgumentError) { invoice(lines: [{name: "Post", quantity: 1, unit_price: 10}]) }
    assert_raises(ArgumentError) { invoice(lines: [{name: "Post", quantity: 1, unit_price: 10, vat_rate: 20, colour: "red"}]) }
    assert_raises(ArgumentError) { invoice(lines: [{name: "Post", quantity: 1, unit_price: 10, vat_category: :exempt, vat_rate: 20}]) }
    assert_raises(ArgumentError) { invoice(lines: []) }
    assert_raises(ArgumentError) { invoice(currency: "euro") }
    assert_raises(ArgumentError) { invoice(allowances: [{amount: 5, reason: "Discount"}]) }
    assert_raises(ArgumentError) { invoice(charges: [{amount: 5, vat_rate: 20}]) }
    assert_raises(ArgumentError) { invoice(seller: SELLER.merge(electronic_address: {id: "alice@example.com"})) }
  end

  def test_an_invoice_is_immutable
    invoice = mixed_invoice

    assert_predicate invoice, :frozen?
    assert_predicate invoice.lines, :frozen?
    assert_raises(FrozenError) { invoice.lines << invoice.lines.first }
  end

  private

  def invoice(**changes)
    Gamba::Invoice.new(number: "INV-1", issued_on: Date.new(2026, 11, 1), due_on: Date.new(2026, 12, 1), seller: SELLER, buyer: BUYER,
      lines: [{name: "Post", quantity: 1, unit_price: 10, vat_rate: 20}], **changes)
  end

  def simple_invoice
    Gamba::Invoice.new(number: "INV-2026-0001", issued_on: Date.new(2026, 11, 1), delivered_on: Date.new(2026, 11, 1), due_on: Date.new(2026, 12, 1),
      seller: SELLER, buyer: BUYER, notes: FRENCH_NOTES, lines: [{name: "Widget", quantity: 2, unit_price: "1000.00", vat_rate: "20.00"}])
  end

  def mixed_invoice
    Gamba::Invoice.new(
      number: "INV-2026-0002", issued_on: Date.new(2026, 11, 12), delivered_on: Date.new(2026, 10, 31), due_on: Date.new(2026, 12, 12), period: Date.new(2026, 10, 1)..Date.new(2026, 10, 31),
      seller: SELLER, buyer: BUYER.merge(vat: "FR40987654321"), buyer_reference: "alice", order_reference: "PO-42", notes: FRENCH_NOTES,
      payment: {iban: "FR76 3000 6000 0112 3456 7890 189", bic: "AGRIFRPP", account_name: "Example Seller Ltd", reference: "INV-2026-0002"},
      payment_terms: "30 days from the invoice date", paid: "100.00",
      lines: [
        {name: "Post", quantity: 3, unit: "H87", unit_price: "12.4567", vat_rate: 20, charges: [{amount: "5.00", reason: "Packing"}], allowances: [{amount: "3.16", reason_code: "95"}]},
        {name: "Comment", description: "Moderation, by the hour", quantity: "1.5", unit: "HUR", unit_price: "89.9000", vat_rate: 10},
        {name: "Book", quantity: 7, unit_price: "10.25", vat_rate: "5.5"}
      ],
      allowances: [{amount: "10.00", reason: "Loyalty discount", vat_rate: 20}],
      charges: [{amount: "12.50", reason: "Delivery", reason_code: "DL", vat_rate: 20}]
    )
  end

  def exempt_invoice
    Gamba::Invoice.new(number: "INV-2026-0003", issued_on: Date.new(2026, 11, 12), delivered_on: Date.new(2026, 11, 5), due_on: Date.new(2026, 12, 12),
      seller: SELLER.merge(vat: nil, tax_registration: "12345678900012"), buyer: BUYER, notes: FRENCH_NOTES,
      lines: [{name: "Lesson", quantity: 4, unit_price: 45, vat_category: :exempt}],
      exemptions: {exempt: {reason: "TVA non applicable, art. 293 B du CGI", code: "VATEX-FR-FRANCHISE"}})
  end

  def reverse_charge_invoice
    Gamba::Invoice.new(number: "INV-2026-0004", issued_on: Date.new(2026, 11, 12), delivered_on: Date.new(2026, 11, 10), due_on: Date.new(2026, 12, 12),
      seller: SELLER, buyer: BUYER.merge(vat: "FR40987654321"), notes: FRENCH_NOTES,
      lines: [{name: "Construction work", quantity: 1, unit_price: "12000.00", vat_category: :reverse_charge}],
      exemptions: {reverse_charge: {reason: "Autoliquidation", code: "VATEX-EU-AE"}})
  end

  def credit_note
    Gamba::Invoice.new(number: "CN-2026-0001", type: :credit_note, preceding_invoice: {number: "INV-2026-0001", issued_on: Date.new(2026, 11, 1)}, issued_on: Date.new(2026, 11, 20), delivered_on: Date.new(2026, 11, 1),
      seller: SELLER, buyer: BUYER, notes: FRENCH_NOTES, payment_terms: "Refunded by transfer",
      lines: [{name: "Widget returned", quantity: 1, unit_price: "1000.00", vat_rate: 20}])
  end

  def text(xml, path)
    REXML::XPath.first(xml, path, NAMESPACES)&.text
  end

  def texts(xml, path)
    REXML::XPath.match(xml, path, NAMESPACES).map(&:text)
  end
end
