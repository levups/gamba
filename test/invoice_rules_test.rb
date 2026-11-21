# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"
require "tmpdir"

# Each business rule Gamba checks, broken by one change to a valid French invoice: Gamba names the rule, and Mustang,
# given the same invoice written unchecked, reports it too.
class InvoiceRulesTest < Minitest::Test
  MUSTANG_JAR = ENV.fetch("MUSTANG_JAR", File.expand_path("~/.cache/gamba-tools/Mustang-CLI.jar"))
  JAVA = ENV.fetch("JAVA", ["/opt/homebrew/opt/openjdk/bin/java", "java"].find { system(_1, "-version", err: File::NULL, out: File::NULL) })
  FONT = File.join(Oracle::ROOT, "corpus/cache/prawn/data/fonts/DejaVuSans.ttf")

  SELLER = {
    name: "Example Seller Ltd", legal_id: {id: "123456789", scheme: "0002"}, vat: "FR32123456789",
    address: {lines: "1 Example Street", postcode: "75001", city: "Paris", country: "FR"}, electronic_address: {id: "123456789", scheme: "0225"}
  }.freeze
  BUYER = {
    name: "Example Buyer Inc", legal_id: {id: "987654321", scheme: "0002"},
    address: {lines: "2 Example Avenue", postcode: "69001", city: "Lyon", country: "FR"}, electronic_address: {id: "987654321", scheme: "0225"}
  }.freeze
  NOTES = [
    {text: "Late payment: a fixed compensation of 40 € for recovery costs.", subject: "PMT"},
    {text: "Late payment penalties: three times the legal interest rate.", subject: "PMD"},
    {text: "No discount for early payment.", subject: "AAB"}
  ].freeze
  VALID = {
    number: "INV-2026-0001", issued_on: Date.new(2026, 11, 12), delivered_on: Date.new(2026, 11, 10), due_on: Date.new(2026, 12, 12),
    seller: SELLER, buyer: BUYER, notes: NOTES, lines: [{name: "Post", quantity: 2, unit_price: "50.00", vat_rate: 20}]
  }.freeze
  LINE = VALID[:lines].first

  # A rule, and the change to the valid invoice that breaks it.
  BROKEN_EN16931 = {
    "BR-27" => {lines: [LINE.merge(unit_price: "-5.00")]},
    "BR-29" => {period: Date.new(2026, 11, 30)..Date.new(2026, 11, 1)},
    "BR-61" => {payment: {means: :sepa_credit_transfer}},
    "BR-CO-09" => {seller: SELLER.merge(vat: "32123456789")},
    "BR-CO-25" => {due_on: nil},
    "BR-CO-26" => {seller: SELLER.merge(legal_id: nil, vat: nil, tax_registration: "12345678900012")},
    "BR-S-02" => {seller: SELLER.merge(vat: nil)},
    "BR-S-05" => {lines: [LINE.merge(vat_rate: 0)]},
    "BR-S-10" => {exemptions: {standard: "Not exempt at all"}},
    "BR-E-02" => {seller: SELLER.merge(vat: nil), lines: [LINE.merge(vat_category: :exempt, vat_rate: nil)], exemptions: {exempt: {code: "VATEX-FR-FRANCHISE"}}},
    "BR-E-10" => {lines: [LINE.merge(vat_category: :exempt, vat_rate: nil)]},
    "BR-AE-02" => {buyer: BUYER.merge(legal_id: nil), lines: [LINE.merge(vat_category: :reverse_charge, vat_rate: nil)], exemptions: {reverse_charge: {code: "VATEX-EU-AE"}}},
    "BR-IC-02" => {lines: [LINE.merge(vat_category: :intra_community, vat_rate: nil)], exemptions: {intra_community: {code: "VATEX-EU-IC"}},
                   deliver_to: {address: {city: "Berlin", country: "DE"}}},
    "BR-IC-11" => {delivered_on: nil, buyer: BUYER.merge(vat: "DE123456789"), lines: [LINE.merge(vat_category: :intra_community, vat_rate: nil)],
                   exemptions: {intra_community: {code: "VATEX-EU-IC"}}, deliver_to: {address: {city: "Berlin", country: "DE"}}},
    "BR-IC-12" => {buyer: BUYER.merge(vat: "DE123456789"), lines: [LINE.merge(vat_category: :intra_community, vat_rate: nil)], exemptions: {intra_community: {code: "VATEX-EU-IC"}}},
    "BR-G-02" => {seller: SELLER.merge(vat: nil, tax_registration: "12345678900012"), lines: [LINE.merge(vat_category: :export, vat_rate: nil)], exemptions: {export: {code: "VATEX-EU-G"}}},
    "BR-O-02" => {lines: [LINE.merge(vat_category: :outside_scope, vat_rate: nil)], exemptions: {outside_scope: {code: "VATEX-EU-O"}}},
    "BR-O-11" => {seller: SELLER.merge(vat: nil, tax_registration: "12345678900012"), exemptions: {outside_scope: {code: "VATEX-EU-O"}},
                  lines: [LINE, LINE.merge(vat_category: :outside_scope, vat_rate: nil)]}
  }.freeze

  BROKEN_FR = {
    "BR-FR-01" => {number: "INV-#{"0" * 40}"},
    "BR-FR-02" => {number: "INV 2026 0001"},
    "BR-FR-03" => {issued_on: Date.new(1999, 12, 31)},
    "BR-FR-05" => {notes: NOTES.drop(1)},
    "BR-FR-06" => {notes: NOTES + [NOTES.first]},
    "BR-FR-10" => {seller: SELLER.merge(legal_id: {id: "123456789"})},
    "BR-FR-11" => {buyer: BUYER.merge(legal_id: nil), notes: NOTES + [{text: "B2B", subject: "BAR"}]},
    "BR-FR-12" => {buyer: BUYER.merge(electronic_address: nil)},
    "BR-FR-13" => {seller: SELLER.merge(electronic_address: nil)},
    "BR-FR-15" => {lines: [LINE.merge(vat_category: :canary_islands, vat_rate: 7)]},
    "BR-FR-16" => {lines: [LINE.merge(vat_rate: 21)]},
    "BR-FR-20" => {notes: NOTES + [{text: "B2X", subject: "BAR"}]},
    "BR-FR-21" => {buyer: BUYER.merge(electronic_address: {id: "alice", scheme: "0225"}), notes: NOTES + [{text: "B2B", subject: "BAR"}]},
    "BR-FR-23" => {seller: SELLER.merge(electronic_address: {id: "123456789@example", scheme: "0225"})},
    "BR-FR-25" => {buyer: BUYER.merge(electronic_address: {id: "#{"a" * 120}@example.com", scheme: "EM"})},
    "BR-FR-30" => {notes: NOTES + [{text: "B2B", subject: "BAR"}, {text: "B2C", subject: "BAR"}]},
    "BR-FR-CO-05" => {type: :credit_note, preceding_invoice: "INV-2026-0000"},
    "BR-FR-CO-07" => {due_on: Date.new(2026, 11, 1)},
    "BR-FR-CO-12" => {currency: "USD"},
    "BR-FR-DEC-02" => {lines: [LINE.merge(quantity: "1.23456")]},
    "BR-FR-DEC-03" => {lines: [LINE.merge(unit_price: "1.1234567")]}
  }.freeze

  # Where Mustang's syntax rules report a rule under their own id: CII writes BR-61's account only when it has one.
  MUSTANG_ID_BY_RULE = {"BR-61" => "CII-SR-470"}.freeze

  def test_the_valid_invoice_breaks_no_rule
    assert_empty invoice.violations(rules: :fr)
  end

  def test_gamba_names_each_broken_en16931_rule
    BROKEN_EN16931.each do |rule, changes|
      assert_includes invoice(**changes).violations.map(&:rule), rule, changes.inspect
    end
  end

  def test_gamba_names_each_broken_french_rule_only_when_asked
    BROKEN_FR.each do |rule, changes|
      broken = invoice(**changes)

      assert_includes broken.violations(rules: :fr).map(&:rule), rule, changes.inspect
      refute_includes broken.violations.map(&:rule), rule
    end
  end

  def test_writing_raises_with_every_broken_rule
    broken = invoice(due_on: nil, notes: [])

    assert_equal ["BR-CO-25"], assert_raises(Gamba::Invoice::RuleViolation) { broken.to_xml }.violations.map(&:rule)
    error = assert_raises(Gamba::Invoice::RuleViolation) { Prawn::Document.new(pdf_a: true).factur_x(broken, rules: :fr) }
    assert_equal %w[BR-CO-25 BR-FR-05 BR-FR-05 BR-FR-05], error.violations.map(&:rule)
    assert_match(/^BR-CO-25: an invoice with an amount due needs due_on or payment_terms$/, error.message)
    assert_includes broken.to_xml(rules: nil), "CrossIndustryInvoice"
  end

  def test_an_unknown_rule_set_raises
    assert_raises(ArgumentError) { invoice.violations(rules: :de) }
  end

  def test_an_intra_community_supply_with_its_delivery_passes_mustang
    skip_without_mustang
    supply = invoice(buyer: BUYER.merge(vat: "DE123456789"), lines: [LINE.merge(vat_category: :intra_community, vat_rate: nil)],
      exemptions: {intra_community: {reason: "Exonération, article 262 ter I du CGI", code: "VATEX-EU-IC"}},
      deliver_to: {name: "Example Warehouse", address: {lines: "3 Example Strasse", postcode: "10115", city: "Berlin", country: "DE"}})

    assert_empty supply.violations(rules: :fr)
    assert_equal [], mustang_rules(supply)
  end

  def test_mustang_reports_each_rule_gamba_names
    skip_without_mustang
    cases = BROKEN_EN16931.merge(BROKEN_FR)
    reported = cases.each_slice((cases.size / 4.0).ceil).map do |slice|
      Thread.new { slice.to_h { |rule, changes| [rule, mustang_rules(invoice(**changes))] } }
    end.map(&:value).reduce(:merge)

    cases.each_key do |rule|
      expected = MUSTANG_ID_BY_RULE.fetch(rule, rule)
      assert reported[rule].any? { _1 == expected || _1.start_with?("#{expected}_") }, "#{rule}: Mustang reported #{reported[rule].inspect}"
    end
  end

  private

  def invoice(**changes)
    Gamba::Invoice.new(**VALID, **changes)
  end

  def skip_without_mustang
    skip "Mustang or Java is not installed" unless JAVA && File.exist?(MUSTANG_JAR)
    skip CORPUS_MISSING_MESSAGE unless File.exist?(FONT)
  end

  # The rule ids Mustang reports for the invoice, written without Gamba's checks.
  def mustang_rules(invoice)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "invoice.pdf")
      Gamba.document(pdf_a: true, info: {Title: "Invoice"}) do |document|
        document.style :default, font: FONT
        document.text "Invoice"
        document.factur_x invoice, rules: nil
      end.write(path)
      report, = Open3.capture2e(JAVA, "-jar", MUSTANG_JAR, "--action", "validate", "--source", path, "--no-notices")
      report[/ErrorIDs: \[(.*?)\]/, 1].to_s.split(",").map(&:strip)
    end
  end
end
