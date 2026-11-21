# frozen_string_literal: true

require "date"

module Gamba
  # An invoice as data: what its Factur-X XML says and what its pages show, from one source. Amounts are exact
  # Rationals, given as Strings such as "12.50", Integers, Rationals or BigDecimals, never Floats; totals and the
  # VAT breakdown are computed with EN 16931's rounding, each amount to the cent.
  Invoice = Data.define(:number, :type, :issued_on, :currency, :seller, :buyer, :lines, :allowances, :charges, :due_on,
    :delivered_on, :period, :buyer_reference, :order_reference, :preceding_invoice, :notes, :payment, :payment_terms,
    :exemptions, :paid)

  class Invoice
    TYPE_CODE_BY_NAME = {invoice: "380", credit_note: "381"}.freeze
    # EN 16931's VAT category codes (UNTDID 5305).
    VAT_CATEGORY_CODE_BY_NAME = {
      standard: "S", zero_rated: "Z", exempt: "E", reverse_charge: "AE", intra_community: "K", export: "G",
      outside_scope: "O", canary_islands: "L", ceuta_melilla: "M"
    }.freeze
    RATED_VAT_CATEGORIES = %i[standard canary_islands ceuta_melilla].freeze
    # UNTDID 4461.
    PAYMENT_MEANS_CODE_BY_NAME = {cash: "10", cheque: "20", credit_transfer: "30", card: "48", sepa_credit_transfer: "58"}.freeze
    DECIMAL = /\A-?\d+(?:\.\d+)?\z/

    def self.decimal(value, name)
      case value
      when Float then raise ArgumentError, "#{name} is the Float #{value}: give a String such as \"12.50\", an Integer, a Rational or a BigDecimal"
      when String
        raise ArgumentError, "#{name} is #{value.inspect}: give a decimal such as \"12.50\"" unless value.match?(DECIMAL)

        Rational(value)
      when Integer, Rational then value.to_r
      else
        raise ArgumentError, "#{name} is #{value.inspect}: give a String such as \"12.50\", an Integer, a Rational or a BigDecimal" unless value.respond_to?(:to_r)

        value.to_r
      end
    end

    def self.cents(value)
      value.round(2, half: :up)
    end

    def self.text(value, name, required: false)
      return if value.nil? && !required
      raise ArgumentError, "#{name} is #{value.inspect}: give a non-empty String" unless value.is_a?(String) && !value.strip.empty?

      value
    end

    def self.date(value, name, required: false)
      return if value.nil? && !required
      raise ArgumentError, "#{name} is #{value.inspect}: give a Date" unless value.is_a?(Date)

      value
    end

    def self.build(type, value, name)
      return value if value.is_a?(type)
      raise ArgumentError, "#{name} is #{value.inspect}: give a Hash" unless value.is_a?(Hash)

      type.new(**value)
    end

    def self.list(type, values, name)
      raise ArgumentError, "#{name} is #{values.inspect}: give an Array" unless values.is_a?(Array)

      values.each_with_index.map { |value, index| build(type, value, "#{name}[#{index}]") }.freeze
    end

    def self.choice(value, choices, name)
      return value if choices.key?(value)

      raise ArgumentError, "#{name} is #{value.inspect}: #{choices.keys.map(&:inspect).join(", ")}"
    end

    # A VAT category and its rate: the rated categories need one, the others have none or 0.
    def self.vat(category, rate, name)
      choice(category, VAT_CATEGORY_CODE_BY_NAME, "#{name} vat_category")
      if RATED_VAT_CATEGORIES.include?(category)
        raise ArgumentError, "#{name} is #{category.inspect}: give its vat_rate" if rate.nil?

        decimal(rate, "#{name} vat_rate")
      elsif category == :outside_scope
        raise ArgumentError, "#{name} is outside the scope of VAT: it takes no vat_rate" unless rate.nil?
      else
        raise ArgumentError, "#{name} is #{category.inspect}: its vat_rate is 0" unless rate.nil? || decimal(rate, "#{name} vat_rate").zero?

        0r
      end
    end

    Identifier = Data.define(:id, :scheme) do
      def initialize(id:, scheme: nil)
        super(id: Invoice.text(id, "id", required: true), scheme: Invoice.text(scheme, "scheme"))
      end
    end

    Address = Data.define(:lines, :postcode, :city, :subdivision, :country) do
      def initialize(country:, lines: [], postcode: nil, city: nil, subdivision: nil)
        lines = Array(lines)
        raise ArgumentError, "an address has at most three lines, not #{lines.size}" if lines.size > 3
        raise ArgumentError, "country is #{country.inspect}: give its ISO 3166 code, such as \"FR\"" unless country.is_a?(String) && country.match?(/\A[A-Z]{2}\z/)

        super(lines: lines.map { Invoice.text(_1, "address line", required: true) }.freeze, postcode: Invoice.text(postcode, "postcode"),
              city: Invoice.text(city, "city"), subdivision: Invoice.text(subdivision, "subdivision"), country:)
      end
    end

    # vat is the VAT identifier; tax_registration, the local one a seller without it gives (BT-32).
    Party = Data.define(:name, :trading_name, :legal_id, :vat, :tax_registration, :address, :electronic_address) do
      def initialize(name:, address:, trading_name: nil, legal_id: nil, vat: nil, tax_registration: nil, electronic_address: nil)
        legal_id = {id: legal_id} if legal_id.is_a?(String)
        super(name: Invoice.text(name, "name", required: true), trading_name: Invoice.text(trading_name, "trading_name"),
              legal_id: legal_id && Invoice.build(Identifier, legal_id, "legal_id"), vat: Invoice.text(vat, "vat"),
              tax_registration: Invoice.text(tax_registration, "tax_registration"),
              address: Invoice.build(Address, address, "address"),
              electronic_address: electronic_address && Invoice.build(Identifier, electronic_address, "electronic_address"))
        raise ArgumentError, "electronic_address needs its scheme, such as \"0225\" or \"EM\"" if self.electronic_address && !self.electronic_address.scheme
      end
    end

    # An allowance or a charge: on a line, or on the whole invoice with the VAT category it falls in.
    Adjustment = Data.define(:amount, :reason, :reason_code, :vat_category, :vat_rate) do
      def initialize(amount:, reason: nil, reason_code: nil, vat_category: nil, vat_rate: nil)
        rated = vat_category || vat_rate
        super(amount: Invoice.cents(Invoice.decimal(amount, "amount")), reason: Invoice.text(reason, "reason"),
              reason_code: Invoice.text(reason_code, "reason_code"), vat_category: rated && (vat_category || :standard),
              vat_rate: rated && Invoice.vat(vat_category || :standard, vat_rate, "an allowance or charge"))
      end
    end

    Line = Data.define(:id, :name, :description, :quantity, :unit, :unit_price, :vat_category, :vat_rate, :allowances, :charges) do
      def initialize(name:, quantity:, unit_price:, id: nil, description: nil, unit: "C62", vat_category: :standard, vat_rate: nil, allowances: [], charges: [])
        super(id: id && Invoice.text(id.to_s, "id"), name: Invoice.text(name, "name", required: true), description: Invoice.text(description, "description"),
              quantity: Invoice.decimal(quantity, "quantity"), unit: Invoice.text(unit, "unit", required: true), unit_price: Invoice.decimal(unit_price, "unit_price"),
              vat_category:, vat_rate: Invoice.vat(vat_category, vat_rate, "line #{name.inspect}"),
              allowances: Invoice.list(Adjustment, allowances, "allowances"), charges: Invoice.list(Adjustment, charges, "charges"))
      end

      # BT-131: quantity times net price, plus the line's charges, minus its allowances.
      def net_amount
        Invoice.cents(quantity * unit_price) + charges.sum(0r, &:amount) - allowances.sum(0r, &:amount)
      end
    end

    Note = Data.define(:text, :subject) do
      def initialize(text:, subject: nil)
        super(text: Invoice.text(text, "note", required: true), subject: Invoice.text(subject, "note subject"))
      end
    end

    Payment = Data.define(:means, :iban, :bic, :account_name, :reference) do
      def initialize(means: :sepa_credit_transfer, iban: nil, bic: nil, account_name: nil, reference: nil)
        super(means: Invoice.choice(means, PAYMENT_MEANS_CODE_BY_NAME, "payment means"), iban: iban && Invoice.text(iban.delete(" "), "iban"),
              bic: Invoice.text(bic, "bic"), account_name: Invoice.text(account_name, "account_name"), reference: Invoice.text(reference, "payment reference"))
      end
    end

    # The invoice a credit note corrects (BT-25), with its date (BT-26), which French rules ask for.
    Reference = Data.define(:number, :issued_on) do
      def initialize(number:, issued_on: nil)
        super(number: Invoice.text(number, "preceding_invoice number", required: true), issued_on: Invoice.date(issued_on, "preceding_invoice issued_on"))
      end
    end

    Exemption = Data.define(:reason, :code) do
      def initialize(reason: nil, code: nil)
        raise ArgumentError, "an exemption takes a reason, a code (VATEX), or both" unless reason || code

        super(reason: Invoice.text(reason, "exemption reason"), code: Invoice.text(code, "exemption code"))
      end
    end

    # One line of the VAT breakdown (BG-23): a category and rate, the amount taxed and the tax.
    TaxBreakdown = Data.define(:vat_category, :vat_rate, :basis, :amount, :exemption)

    def initialize(number:, issued_on:, seller:, buyer:, lines:, type: :invoice, currency: "EUR", allowances: [], charges: [], due_on: nil,
      delivered_on: nil, period: nil, buyer_reference: nil, order_reference: nil, preceding_invoice: nil, notes: [], payment: nil,
      payment_terms: nil, exemptions: {}, paid: 0)
      raise ArgumentError, "currency is #{currency.inspect}: give its ISO 4217 code, such as \"EUR\"" unless currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/)
      raise ArgumentError, "an invoice has at least one line" if lines.is_a?(Array) && lines.empty?
      raise ArgumentError, "period is #{period.inspect}: give a Range of two Dates" if period && !(period.is_a?(Range) && period.begin.is_a?(Date) && period.end.is_a?(Date))
      raise ArgumentError, "exemptions is #{exemptions.inspect}: give a Hash by VAT category" unless exemptions.is_a?(Hash)

      super(
        number: Invoice.text(number, "number", required: true), type: Invoice.choice(type, TYPE_CODE_BY_NAME, "type"),
        issued_on: Invoice.date(issued_on, "issued_on", required: true), currency:,
        seller: Invoice.build(Party, seller, "seller"), buyer: Invoice.build(Party, buyer, "buyer"),
        lines: Invoice.list(Line, lines, "lines"), allowances: Invoice.list(Adjustment, allowances, "allowances"), charges: Invoice.list(Adjustment, charges, "charges"),
        due_on: Invoice.date(due_on, "due_on"), delivered_on: Invoice.date(delivered_on, "delivered_on"), period:,
        buyer_reference: Invoice.text(buyer_reference, "buyer_reference"), order_reference: Invoice.text(order_reference, "order_reference"),
        preceding_invoice: preceding_invoice && Invoice.build(Reference, preceding_invoice.is_a?(String) ? {number: preceding_invoice} : preceding_invoice, "preceding_invoice"),
        notes: Invoice.list(Note, notes.map { _1.is_a?(String) ? {text: _1} : _1 }, "notes"),
        payment: payment && Invoice.build(Payment, payment, "payment"), payment_terms: Invoice.text(payment_terms, "payment_terms"),
        exemptions: exemptions.to_h { |category, exemption| [Invoice.choice(category, VAT_CATEGORY_CODE_BY_NAME, "exemption category"), Invoice.build(Exemption, exemption.is_a?(String) ? {reason: exemption} : exemption, "exemption")] }.freeze,
        paid: Invoice.cents(Invoice.decimal(paid, "paid"))
      )
      document_adjustments = self.allowances + self.charges
      raise ArgumentError, "an invoice's allowances and charges each take a vat_category or a vat_rate" unless document_adjustments.all?(&:vat_category)
      raise ArgumentError, "an allowance or charge takes a reason, a reason_code, or both" unless (document_adjustments + self.lines.flat_map { _1.allowances + _1.charges }).all? { _1.reason || _1.reason_code }
    end

    # BT-106
    def line_total
      lines.sum(0r, &:net_amount)
    end

    # BT-107
    def allowance_total
      allowances.sum(0r, &:amount)
    end

    # BT-108
    def charge_total
      charges.sum(0r, &:amount)
    end

    # BT-109
    def tax_basis_total
      line_total - allowance_total + charge_total
    end

    # BG-23, one entry for each VAT category and rate, in the order they first appear.
    def tax_breakdown
      basis_by_vat = Hash.new(0r)
      lines.each { basis_by_vat[[_1.vat_category, _1.vat_rate]] += _1.net_amount }
      charges.each { basis_by_vat[[_1.vat_category, _1.vat_rate]] += _1.amount }
      allowances.each { basis_by_vat[[_1.vat_category, _1.vat_rate]] -= _1.amount }
      basis_by_vat.map do |(category, rate), basis|
        TaxBreakdown.new(vat_category: category, vat_rate: rate, basis:, amount: Invoice.cents(basis * (rate || 0) / 100), exemption: exemptions[category])
      end
    end

    # BT-110
    def tax_total
      tax_breakdown.sum(0r, &:amount)
    end

    # BT-112
    def grand_total
      tax_basis_total + tax_total
    end

    # BT-115
    def due
      grand_total - paid
    end

    # The Cross Industry Invoice XML of the profile, as Factur-X and ZUGFeRD embed it.
    def to_xml(profile: :en16931)
      CrossIndustryInvoice.new(self, profile).to_s
    end
  end
end
