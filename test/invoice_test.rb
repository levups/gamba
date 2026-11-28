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

  # Every invoice in EN 16931, the one using every field in each profile, and in extended those whose exemptions it
  # repeats on each line.
  def test_each_invoice_passes_mustang_in_each_profile
    skip "Mustang or Java is not installed" unless JAVA && File.exist?(MUSTANG_JAR)
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)

    invoices = {simple: simple_invoice, mixed: mixed_invoice, exempt: exempt_invoice, reverse_charge: reverse_charge_invoice, credit_note: credit_note, full: full_invoice}
    cases = invoices.map { |name, invoice| [:en16931, name, invoice] } +
      %i[minimum basic_wl basic extended].map { [_1, :full, full_invoice] } + %i[exempt reverse_charge].map { [:extended, _1, invoices[_1]] }
    cases.each do |profile, name, invoice|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "#{name}.pdf")
        Gamba.document(pdf_a: true, info: {Title: "Invoice #{invoice.number}"}) do |document|
          document.style :default, font: FONT
          document.text "Invoice #{invoice.number}"
          document.factur_x invoice, profile:
        end.write(path)
        report, = Open3.capture2e(JAVA, "-jar", MUSTANG_JAR, "--action", "validate", "--source", path, "--no-notices")
        summary = report[/Parsed PDF:.*/]

        assert_match(/Parsed PDF:valid XML:valid/, summary, "#{profile} #{name}: #{report}")
        assert_match(/Errors:\[\]/, summary, "#{profile} #{name}: #{report}")
      end
    end
  end

  def test_each_profile_writes_what_its_schema_holds
    xml_by_profile = Gamba::Invoice::CrossIndustryInvoice::PROFILES.to_h { [_1, REXML::Document.new(full_invoice.to_xml(profile: _1))] }
    present = ->(path) { xml_by_profile.select { |_profile, xml| REXML::XPath.first(xml, path, NAMESPACES) }.keys }

    assert_equal "urn:factur-x.eu:1p0:minimum", text(xml_by_profile[:minimum], "//ram:GuidelineSpecifiedDocumentContextParameter/ram:ID")
    assert_equal %i[basic en16931 extended], present["//ram:IncludedSupplyChainTradeLineItem"]
    assert_equal %i[en16931 extended], present["//ram:SpecifiedTradeProduct/ram:Description"]
    assert_equal %i[en16931 extended], present["//ram:PayeeSpecifiedCreditorFinancialInstitution"]
    assert_equal %i[basic_wl basic en16931 extended], present["//ram:IncludedNote"]
    assert_equal %i[basic_wl basic en16931 extended], present["//ram:BuyerTradeParty/ram:PostalTradeAddress"]
    assert_equal ["FR"], texts(xml_by_profile[:minimum], "//ram:SellerTradeParty/ram:PostalTradeAddress/*")
    assert_equal %w[TaxBasisTotalAmount TaxTotalAmount GrandTotalAmount DuePayableAmount],
      REXML::XPath.match(xml_by_profile[:minimum], "//ram:SpecifiedTradeSettlementHeaderMonetarySummation/*", NAMESPACES).map(&:name)
    assert_equal ["VATEX-FR-FRANCHISE"] * 2, texts(REXML::Document.new(exempt_invoice.to_xml(profile: :extended)), "//ram:ExemptionReasonCode")
    assert_includes full_invoice.to_xml(profile: :minimum), "<ram:ApplicableHeaderTradeDelivery/>"
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

  def test_an_invoice_read_back_from_its_xml_writes_the_same_xml
    [simple_invoice, mixed_invoice, exempt_invoice, reverse_charge_invoice, credit_note, full_invoice].product(%i[basic en16931 extended]).each do |invoice, profile|
      xml = invoice.to_xml(profile:)

      assert_equal xml, Gamba::Invoice.from_xml(xml).to_xml(profile:), "#{invoice.number} in #{profile}"
    end
  end

  def test_an_invoice_read_from_xml_takes_a_price_per_basis_quantity_and_must_owe_what_the_xml_states
    xml = simple_invoice.to_xml
    per_ten = xml.sub("<ram:ChargeAmount>1000.00</ram:ChargeAmount>", %(<ram:ChargeAmount>10000.00</ram:ChargeAmount>\n<ram:BasisQuantity unitCode="C62">10</ram:BasisQuantity>))

    assert_equal 1000, Gamba::Invoice.from_xml(per_ten).lines.first.unit_price
    error = assert_raises(ArgumentError) { Gamba::Invoice.from_xml(xml.sub("<ram:GrandTotalAmount>2400.00", "<ram:GrandTotalAmount>2400.01")) }
    assert_match(/GrandTotalAmount is 2400.01, and Gamba computes 2400.0/, error.message)
  end

  def test_xml_gamba_cannot_read_raises
    {
      simple_invoice.to_xml(profile: :minimum) => /no lines, as in the minimum and basic WL profiles/,
      simple_invoice.to_xml.sub("<ram:TypeCode>380", "<ram:TypeCode>384") => /type code "384"/,
      mixed_invoice.to_xml.sub("<ram:TypeCode>58", "<ram:TypeCode>31") => /payment means code "31"/,
      "<Invoice/>" => /not a Cross Industry Invoice/,
      "<rsm:CrossIndustryInvoice" => /cannot be read/
    }.each do |xml, message|
      error = assert_raises(ArgumentError) { Gamba::Invoice.from_xml(xml) }
      assert_match message, error.message
    end
  end

  def test_an_unknown_profile_raises
    error = assert_raises(ArgumentError) { simple_invoice.to_xml(profile: :comfort) }

    assert_match(/Unknown Factur-X profile :comfort/, error.message)
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
    error = assert_raises(ArgumentError) { invoice(buyer: BUYER.merge(tax_registration: "98765432100012")) }
    assert_match(/tax_registration to the seller only/, error.message)
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

  # Every field a profile may leave out: trading names, a full address, a delivery address, payment details.
  def full_invoice
    mixed = mixed_invoice
    mixed.with(
      seller: mixed.seller.with(trading_name: "Example Trade", tax_registration: "12345678900012", address: mixed.seller.address.with(lines: ["1 Example Street", "Building B", "Floor 2"], subdivision: "IDF")),
      buyer: mixed.buyer.with(legal_id: Gamba::Invoice::Identifier.new(id: "987654321", scheme: "0002"), trading_name: "Example Buying"),
      deliver_to: Gamba::Invoice::Delivery.new(name: "alice", address: mixed.buyer.address)
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
