# frozen_string_literal: true

module Gamba
  class Invoice
    # Raised when an invoice breaks business rules: each violation names its rule, as validators report it.
    class RuleViolation < StandardError
      attr_reader :violations

      def initialize(violations)
        @violations = violations
        super(violations.map { "#{_1.rule}: #{_1.message}" }.join("\n"))
      end
    end

    Violation = Data.define(:rule, :message)

    # The business rules of EN 16931 an invoice built from this data can break, and with :fr those France adds
    # for its e-invoicing reform (XP Z12-012, BR-FR). What Gamba computes, such as totals and the VAT breakdown, holds
    # by construction and is not checked again.
    class Rules
      RULE_SETS = %i[en16931 fr].freeze
      # Categories whose breakdown states why no VAT is due, and those that state none (BR-x-10).
      EXEMPTION_REQUIRED = %i[exempt reverse_charge intra_community export outside_scope].freeze
      # How EN 16931 names its rules on a VAT category, where that is not the category's code.
      RULE_PREFIX_BY_CATEGORY_CODE = {"K" => "IC", "L" => "AF", "M" => "AG"}.freeze
      NOT_IN_FRANCE = %i[canary_islands ceuta_melilla].freeze
      # The rates France accepts (BR-FR-16).
      FRENCH_VAT_RATES = %w[0 10 13 20 8.5 19.6 2.1 5.5 7 20.6 1.05 0.9 1.75 9.2 9.6].map { Rational(_1) }.freeze
      FRENCH_ID = %r{\A[A-Za-z0-9+\-_/]+\z}
      SIREN = /\A\d{9}\z/
      SIREN_SCHEME = "0002"
      FRENCH_LEGAL_NOTES = %w[PMT PMD AAB].freeze
      BILLING_TREATMENTS = %w[B2B B2BINT B2C OUTOFSCOPE ARCHIVEONLY].freeze

      def self.check(invoice, rules)
        raise ArgumentError, "rules is #{rules.inspect}: #{RULE_SETS.map(&:inspect).join(", ")}, or nil to write without checking" unless rules.nil? || RULE_SETS.include?(rules)
        return [] if rules.nil?

        rules_set = new(invoice)
        rules_set.en16931
        rules_set.fr if rules == :fr
        rules_set.violations
      end

      attr_reader :violations

      def initialize(invoice)
        @invoice = invoice
        @violations = []
      end

      def en16931
        seller = @invoice.seller
        buyer = @invoice.buyer
        categories = vat_categories

        @invoice.lines.each { violation("BR-27", "line #{_1.name.inspect} has a negative unit_price") if _1.unit_price.negative? }
        violation("BR-29", "the period ends before it starts") if @invoice.period && @invoice.period.end < @invoice.period.begin
        if %i[credit_transfer sepa_credit_transfer].include?(@invoice.payment&.means) && !@invoice.payment.iban
          violation("BR-61", "payment by #{@invoice.payment.means.to_s.tr("_", " ")} needs the iban")
        end
        {seller:, buyer:}.each do |role, party|
          violation("BR-CO-09", "the #{role}'s vat must start with its country's code, such as FR") if party.vat && !party.vat.match?(/\A[A-Z]{2}/)
        end
        violation("BR-CO-25", "an invoice with an amount due needs due_on or payment_terms") if @invoice.due.positive? && !@invoice.due_on && !@invoice.payment_terms
        violation("BR-CO-26", "the seller needs a legal_id or a vat") unless seller.legal_id || seller.vat

        seller_taxed = seller.vat || seller.tax_registration
        {standard: "BR-S-02", zero_rated: "BR-Z-02", exempt: "BR-E-02", canary_islands: "BR-AF-02", ceuta_melilla: "BR-AG-02"}.each do |category, rule|
          violation(rule, "#{describe(category)} needs the seller's vat or tax_registration") if categories.include?(category) && !seller_taxed
        end
        taxed_items.each do |item|
          violation("BR-S-05", "standard rated VAT needs a rate above 0") if item.vat_category == :standard && !item.vat_rate.positive?
        end
        if categories.include?(:reverse_charge) && !(seller_taxed && (buyer.vat || buyer.legal_id))
          violation("BR-AE-02", "reverse charge needs the seller's vat or tax_registration, and the buyer's vat or legal_id")
        end
        if categories.include?(:intra_community)
          violation("BR-IC-02", "an intra-community supply needs the seller's and the buyer's vat") unless seller.vat && buyer.vat
          violation("BR-IC-11", "an intra-community supply needs delivered_on or the period") unless @invoice.delivered_on || @invoice.period
          violation("BR-IC-12", "an intra-community supply needs deliver_to, with its country") unless @invoice.deliver_to
        end
        violation("BR-G-02", "an export needs the seller's vat") if categories.include?(:export) && !seller.vat
        if categories.include?(:outside_scope)
          violation("BR-O-02", "an invoice outside the scope of VAT takes neither the seller's nor the buyer's vat") if seller.vat || buyer.vat
          violation("BR-O-11", "an invoice outside the scope of VAT has no other VAT category") if categories.size > 1
        end
        categories.each do |category|
          code = VAT_CATEGORY_CODE_BY_NAME.fetch(category)
          rule = "BR-#{RULE_PREFIX_BY_CATEGORY_CODE.fetch(code, code)}-10"
          if EXEMPTION_REQUIRED.include?(category)
            violation(rule, "#{describe(category)} needs its reason in exemptions") unless @invoice.exemptions[category]
          elsif @invoice.exemptions[category]
            violation(rule, "#{describe(category)} takes no exemption reason")
          end
        end
      end

      def fr
        seller = @invoice.seller
        buyer = @invoice.buyer
        subjects = @invoice.notes.map(&:subject)
        treatments = @invoice.notes.filter_map { _1.text if _1.subject == "BAR" }
        treatments.uniq!

        {"invoice number" => @invoice.number, "preceding_invoice number" => @invoice.preceding_invoice&.number}.each do |name, number|
          next unless number

          violation("BR-FR-01", "the #{name} has more than 35 characters") if number.length > 35
          violation("BR-FR-02", "the #{name} holds characters other than letters, digits, + - _ and /") unless number.match?(FRENCH_ID)
        end
        dates.each { |name, date| violation("BR-FR-03", "#{name} is not between 2000 and 2099") unless (2000..2099).cover?(date.year) }
        FRENCH_LEGAL_NOTES.each { violation("BR-FR-05", "French invoices need a note with subject #{_1}") unless subjects.include?(_1) }
        (FRENCH_LEGAL_NOTES + ["TXD"]).each { violation("BR-FR-06", "a single note may have subject #{_1}") if subjects.count(_1) > 1 }
        violation("BR-FR-10", "the seller needs its SIREN, 9 digits, as legal_id with scheme 0002") unless siren(seller)
        violation("BR-FR-11", "a B2B invoice needs the buyer's SIREN, 9 digits, as legal_id with scheme 0002") if treatments.include?("B2B") && !siren(buyer)
        violation("BR-FR-12", "the buyer needs an electronic_address") unless buyer.electronic_address
        violation("BR-FR-13", "the seller needs an electronic_address") unless seller.electronic_address
        vat_categories.each do |category|
          violation("BR-FR-15", "#{describe(category)} does not apply in France") if NOT_IN_FRANCE.include?(category)
        end
        taxed_items.filter_map(&:vat_rate).uniq.each do |rate|
          violation("BR-FR-16", "#{format("%g", rate)}% is not a French VAT rate") unless FRENCH_VAT_RATES.include?(rate)
        end
        treatments.each { violation("BR-FR-20", "a note with subject BAR reads one of #{BILLING_TREATMENTS.join(", ")}") unless BILLING_TREATMENTS.include?(_1) }
        violation("BR-FR-30", "the notes with subject BAR give one treatment") if treatments.size > 1
        if treatments.include?("B2B") && !(buyer.electronic_address&.scheme == "0225" && siren(buyer) && buyer.electronic_address.id.start_with?(siren(buyer)))
          violation("BR-FR-21", "a B2B invoice addresses the buyer by an electronic_address with scheme 0225 starting with its SIREN")
        end
        {seller:, buyer:}.each do |role, party|
          address = party.electronic_address
          next unless address

          violation("BR-FR-23", "the #{role}'s electronic_address holds characters other than letters, digits, + - _ and /") if address.scheme == "0225" && !address.id.match?(FRENCH_ID)
          violation("BR-FR-25", "the #{role}'s electronic_address has more than 125 characters") if address.id.length > 125
        end
        if @invoice.type == :credit_note && !@invoice.preceding_invoice&.issued_on
          violation("BR-FR-CO-05", "a credit note needs the preceding_invoice it corrects, with its issued_on")
        end
        violation("BR-FR-CO-07", "due_on is before issued_on") if @invoice.due_on && @invoice.due_on < @invoice.issued_on
        violation("BR-FR-CO-12", "Gamba writes French invoices in EUR only") unless @invoice.currency == "EUR"
        @invoice.lines.each do |line|
          violation("BR-FR-DEC-02", "line #{line.name.inspect} has a quantity with more than 4 decimals") unless (line.quantity * 10**4).denominator == 1
          violation("BR-FR-DEC-03", "line #{line.name.inspect} has a unit_price with more than 6 decimals") unless (line.unit_price * 10**6).denominator == 1
        end
      end

      private

      def violation(rule, message)
        @violations << Violation.new(rule:, message:)
      end

      # What carries a VAT category: the lines, and the invoice's allowances and charges.
      def taxed_items
        @invoice.lines + @invoice.allowances + @invoice.charges
      end

      def vat_categories
        categories = taxed_items.map(&:vat_category)
        categories.uniq!
        categories
      end

      def describe(category)
        {standard: "standard rated VAT", zero_rated: "zero rated VAT", exempt: "exemption from VAT", reverse_charge: "reverse charge",
         intra_community: "an intra-community supply", export: "an export", outside_scope: "an invoice outside the scope of VAT",
         canary_islands: "Canary Islands IGIC", ceuta_melilla: "Ceuta and Melilla IPSI"}.fetch(category)
      end

      def siren(party)
        legal_id = party.legal_id
        legal_id.id if legal_id&.scheme == SIREN_SCHEME && legal_id.id.match?(SIREN)
      end

      def dates
        {"issued_on" => @invoice.issued_on, "due_on" => @invoice.due_on, "delivered_on" => @invoice.delivered_on,
         "the period's start" => @invoice.period&.begin, "the period's end" => @invoice.period&.end,
         "preceding_invoice issued_on" => @invoice.preceding_invoice&.issued_on}.compact
      end
    end
  end
end
