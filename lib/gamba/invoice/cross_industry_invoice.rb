# frozen_string_literal: true

module Gamba
  class Invoice
    # Writes an invoice as UN/CEFACT Cross Industry Invoice D16B, the syntax of Factur-X and ZUGFeRD, in the element
    # order its schema sets. Each profile writes what its schema holds, the smaller ones a part of EN 16931's:
    # minimum the header and the totals, basic WL all but the lines, basic the lines without their description.
    class CrossIndustryInvoice
      # From the smallest profile to the largest, each with the identifier of its specification.
      GUIDELINE_BY_PROFILE = {
        minimum: "urn:factur-x.eu:1p0:minimum",
        basic_wl: "urn:factur-x.eu:1p0:basicwl",
        basic: "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic",
        en16931: "urn:cen.eu:en16931:2017",
        extended: "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended"
      }.freeze
      PROFILES = GUIDELINE_BY_PROFILE.keys.freeze
      NAMESPACES = {
        "rsm" => "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100",
        "ram" => "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100",
        "udt" => "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100",
        "qdt" => "urn:un:unece:uncefact:data:standard:QualifiedDataType:100"
      }.freeze

      def initialize(invoice, profile)
        @guideline = GUIDELINE_BY_PROFILE.fetch(profile) do
          raise ArgumentError, "Unknown Factur-X profile #{profile.inspect}: #{PROFILES.map(&:inspect).join(", ")}"
        end
        @level = PROFILES.index(profile)
        @invoice = invoice
        @xml = +""
        @depth = 0
      end

      def to_s
        @xml << %(<?xml version="1.0" encoding="UTF-8"?>\n)
        attributes = NAMESPACES.to_h { |prefix, uri| ["xmlns:#{prefix}", uri] }
        element("rsm:CrossIndustryInvoice", **attributes) do
          element("rsm:ExchangedDocumentContext") { element("ram:GuidelineSpecifiedDocumentContextParameter") { element("ram:ID", @guideline) } }
          exchanged_document
          element("rsm:SupplyChainTradeTransaction") do
            @invoice.lines.each_with_index { |line, index| line_item(line, index) } if from?(:basic)
            header_agreement
            header_delivery
            header_settlement
          end
        end
        @xml
      end

      private

      def exchanged_document
        element("rsm:ExchangedDocument") do
          element("ram:ID", @invoice.number)
          element("ram:TypeCode", TYPE_CODE_BY_NAME.fetch(@invoice.type))
          date("ram:IssueDateTime", @invoice.issued_on)
          next unless from?(:basic_wl)

          @invoice.notes.each do |note|
            element("ram:IncludedNote") do
              element("ram:Content", note.text)
              element("ram:SubjectCode", note.subject)
            end
          end
        end
      end

      def line_item(line, index)
        element("ram:IncludedSupplyChainTradeLineItem") do
          element("ram:AssociatedDocumentLineDocument") { element("ram:LineID", line.id || (index + 1).to_s) }
          element("ram:SpecifiedTradeProduct") do
            element("ram:Name", line.name)
            element("ram:Description", line.description) if from?(:en16931)
          end
          element("ram:SpecifiedLineTradeAgreement") { element("ram:NetPriceProductTradePrice") { element("ram:ChargeAmount", decimal(line.unit_price, 2)) } }
          element("ram:SpecifiedLineTradeDelivery") { element("ram:BilledQuantity", decimal(line.quantity), unitCode: line.unit) }
          element("ram:SpecifiedLineTradeSettlement") do
            tax(line.vat_category, line.vat_rate)
            line.allowances.each { adjustment(_1, charge: false) }
            line.charges.each { adjustment(_1, charge: true) }
            element("ram:SpecifiedTradeSettlementLineMonetarySummation") { element("ram:LineTotalAmount", amount(line.net_amount)) }
          end
        end
      end

      def header_agreement
        element("ram:ApplicableHeaderTradeAgreement") do
          element("ram:BuyerReference", @invoice.buyer_reference)
          party("ram:SellerTradeParty", @invoice.seller)
          party("ram:BuyerTradeParty", @invoice.buyer, buyer: true)
          element("ram:BuyerOrderReferencedDocument") { element("ram:IssuerAssignedID", @invoice.order_reference) } if @invoice.order_reference
        end
      end

      def header_delivery
        element("ram:ApplicableHeaderTradeDelivery") do
          next unless from?(:basic_wl)

          if (delivery = @invoice.deliver_to)
            element("ram:ShipToTradeParty") do
              element("ram:Name", delivery.name)
              address(delivery.address)
            end
          end
          element("ram:ActualDeliverySupplyChainEvent") { date("ram:OccurrenceDateTime", @invoice.delivered_on) } if @invoice.delivered_on
        end
      end

      def header_settlement
        element("ram:ApplicableHeaderTradeSettlement") do
          element("ram:PaymentReference", @invoice.payment&.reference) if from?(:basic_wl)
          element("ram:InvoiceCurrencyCode", @invoice.currency)
          next monetary_summation unless from?(:basic_wl)

          payment_means
          @invoice.tax_breakdown.each { tax_breakdown(_1) }
          if @invoice.period
            element("ram:BillingSpecifiedPeriod") do
              date("ram:StartDateTime", @invoice.period.begin)
              date("ram:EndDateTime", @invoice.period.end)
            end
          end
          @invoice.allowances.each { adjustment(_1, charge: false) }
          @invoice.charges.each { adjustment(_1, charge: true) }
          if @invoice.payment_terms || @invoice.due_on
            element("ram:SpecifiedTradePaymentTerms") do
              element("ram:Description", @invoice.payment_terms)
              date("ram:DueDateDateTime", @invoice.due_on) if @invoice.due_on
            end
          end
          monetary_summation
          preceding_invoice
        end
      end

      def preceding_invoice
        reference = @invoice.preceding_invoice
        return unless reference

        element("ram:InvoiceReferencedDocument") do
          element("ram:IssuerAssignedID", reference.number)
          if reference.issued_on
            element("ram:FormattedIssueDateTime") { element("qdt:DateTimeString", reference.issued_on.strftime("%Y%m%d"), format: "102") }
          end
        end
      end

      # The minimum profile gives a party its name, its legal identifier and VAT number, and the seller's country.
      def party(name, party, buyer: false)
        full = from?(:basic_wl)
        element(name) do
          element("ram:Name", party.name)
          trading_name = party.trading_name if full
          if party.legal_id || trading_name
            element("ram:SpecifiedLegalOrganization") do
              element("ram:ID", party.legal_id&.id, schemeID: party.legal_id&.scheme)
              element("ram:TradingBusinessName", trading_name)
            end
          end
          if full
            address(party.address)
          elsif !buyer
            element("ram:PostalTradeAddress") { element("ram:CountryID", party.address.country) }
          end
          element("ram:URIUniversalCommunication") { element("ram:URIID", party.electronic_address.id, schemeID: party.electronic_address.scheme) } if party.electronic_address && full
          element("ram:SpecifiedTaxRegistration") { element("ram:ID", party.vat, schemeID: "VA") } if party.vat
          element("ram:SpecifiedTaxRegistration") { element("ram:ID", party.tax_registration, schemeID: "FC") } if party.tax_registration
        end
      end

      def address(address)
        element("ram:PostalTradeAddress") do
          element("ram:PostcodeCode", address.postcode)
          %w[ram:LineOne ram:LineTwo ram:LineThree].zip(address.lines) { |line_name, line| element(line_name, line) }
          element("ram:CityName", address.city)
          element("ram:CountryID", address.country)
          element("ram:CountrySubDivisionName", address.subdivision)
        end
      end

      def payment_means
        payment = @invoice.payment
        return unless payment

        element("ram:SpecifiedTradeSettlementPaymentMeans") do
          element("ram:TypeCode", PAYMENT_MEANS_CODE_BY_NAME.fetch(payment.means))
          if payment.iban
            element("ram:PayeePartyCreditorFinancialAccount") do
              element("ram:IBANID", payment.iban)
              element("ram:AccountName", payment.account_name) if from?(:en16931)
            end
          end
          element("ram:PayeeSpecifiedCreditorFinancialInstitution") { element("ram:BICID", payment.bic) } if payment.bic && from?(:en16931)
        end
      end

      # The extended profile repeats the exemption of the category where it applies, as its breakdown matches them.
      def tax(category, rate, name = "ram:ApplicableTradeTax")
        exemption = @invoice.exemptions[category] if from?(:extended)
        element(name) do
          element("ram:TypeCode", "VAT")
          element("ram:ExemptionReason", exemption&.reason)
          element("ram:CategoryCode", VAT_CATEGORY_CODE_BY_NAME.fetch(category))
          element("ram:ExemptionReasonCode", exemption&.code)
          element("ram:RateApplicablePercent", decimal(rate, 2)) if rate
        end
      end

      def tax_breakdown(breakdown)
        element("ram:ApplicableTradeTax") do
          element("ram:CalculatedAmount", amount(breakdown.amount))
          element("ram:TypeCode", "VAT")
          element("ram:ExemptionReason", breakdown.exemption&.reason)
          element("ram:BasisAmount", amount(breakdown.basis))
          element("ram:CategoryCode", VAT_CATEGORY_CODE_BY_NAME.fetch(breakdown.vat_category))
          element("ram:ExemptionReasonCode", breakdown.exemption&.code)
          element("ram:RateApplicablePercent", decimal(breakdown.vat_rate, 2)) if breakdown.vat_rate
        end
      end

      def adjustment(adjustment, charge:)
        element("ram:SpecifiedTradeAllowanceCharge") do
          element("ram:ChargeIndicator") { element("udt:Indicator", charge.to_s) }
          element("ram:ActualAmount", amount(adjustment.amount))
          element("ram:ReasonCode", adjustment.reason_code)
          element("ram:Reason", adjustment.reason)
          tax(adjustment.vat_category, adjustment.vat_rate, "ram:CategoryTradeTax") if adjustment.vat_category
        end
      end

      def monetary_summation
        full = from?(:basic_wl)
        element("ram:SpecifiedTradeSettlementHeaderMonetarySummation") do
          element("ram:LineTotalAmount", amount(@invoice.line_total)) if full
          element("ram:ChargeTotalAmount", amount(@invoice.charge_total)) unless !full || @invoice.charges.empty?
          element("ram:AllowanceTotalAmount", amount(@invoice.allowance_total)) unless !full || @invoice.allowances.empty?
          element("ram:TaxBasisTotalAmount", amount(@invoice.tax_basis_total))
          element("ram:TaxTotalAmount", amount(@invoice.tax_total), currencyID: @invoice.currency)
          element("ram:GrandTotalAmount", amount(@invoice.grand_total))
          element("ram:TotalPrepaidAmount", amount(@invoice.paid)) unless !full || @invoice.paid.zero?
          element("ram:DuePayableAmount", amount(@invoice.due))
        end
      end

      # Whether the profile written holds what this one does.
      def from?(profile)
        @level >= PROFILES.index(profile)
      end

      def date(name, date)
        element(name) { element("udt:DateTimeString", date.strftime("%Y%m%d"), format: "102") }
      end

      # An element with its text, or with the elements its block writes, empty when it writes none; one without
      # either is left out.
      def element(name, text = nil, **attributes)
        return if text.nil? && !block_given?

        @xml << ("  " * @depth) << "<" << name
        attributes.each { |attribute, value| @xml << " " << attribute.to_s << "=" << value.encode(xml: :attr) if value }
        if block_given?
          @xml << ">\n"
          empty = @xml.bytesize
          @depth += 1
          yield
          @depth -= 1
          return @xml.bytesplice(empty - 2, 2, "/>\n") if @xml.bytesize == empty

          @xml << ("  " * @depth) << "</" << name << ">\n"
        else
          @xml << ">" << text.encode(xml: :text) << "</" << name << ">\n"
        end
      end

      def amount(value)
        cents = Invoice.cents(value) * 100
        format("%s%d.%02d", cents.negative? ? "-" : "", cents.abs.to_i / 100, cents.abs.to_i % 100)
      end

      # A quantity, price or rate as it was given, with as many decimals as it needs, at least minimum.
      def decimal(value, minimum = 0)
        places = (minimum..9).find { (value * 10**_1).denominator == 1 } || 9
        scaled = (value * 10**places).round(half: :up)
        return format("%s%d", scaled.negative? ? "-" : "", scaled.abs) if places.zero?

        digits = scaled.abs.to_s.rjust(places + 1, "0")
        format("%s%s.%s", scaled.negative? ? "-" : "", digits[0...-places], digits[-places..])
      end
    end
  end
end
