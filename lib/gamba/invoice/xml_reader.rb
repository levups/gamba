# frozen_string_literal: true

require "rexml/document"

module Gamba
  class Invoice
    # Reads the Cross Industry Invoice XML of a Factur-X or ZUGFeRD invoice back into a Gamba::Invoice, from any
    # profile that has lines (basic, EN 16931, extended). What the invoice cannot hold is left out, unless it changes
    # what the invoice owes: the totals Gamba computes must be those the XML states, or the XML is refused.
    class XmlReader
      NAMESPACES = CrossIndustryInvoice::NAMESPACES
      TRANSACTION = "/rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction"
      SETTLEMENT = "#{TRANSACTION}/ram:ApplicableHeaderTradeSettlement".freeze
      AGREEMENT = "#{TRANSACTION}/ram:ApplicableHeaderTradeAgreement".freeze
      DELIVERY = "#{TRANSACTION}/ram:ApplicableHeaderTradeDelivery".freeze
      # The totals the XML states, each against what Gamba computes from the rest.
      CHECKED_TOTALS = {"ram:LineTotalAmount" => :line_total, "ram:TaxBasisTotalAmount" => :tax_basis_total,
                        "ram:GrandTotalAmount" => :grand_total, "ram:DuePayableAmount" => :due}.freeze

      def self.read(xml)
        new(xml).invoice
      end

      def initialize(xml)
        raise ArgumentError, "give the XML as a String, not #{xml.class}" unless xml.is_a?(String)

        @document = REXML::Document.new(xml)
        raise ArgumentError, "this is not a Cross Industry Invoice: its root is #{@document.root&.expanded_name.inspect}" unless first("/rsm:CrossIndustryInvoice")
      rescue REXML::ParseException => error
        raise ArgumentError, "this XML cannot be read: #{error.message.lines.first&.strip}"
      end

      def invoice
        lines = all("#{TRANSACTION}/ram:IncludedSupplyChainTradeLineItem").map { line(_1) }
        if lines.empty?
          raise ArgumentError, "this XML has no lines, as in the minimum and basic WL profiles (#{text(@document, "//ram:GuidelineSpecifiedDocumentContextParameter/ram:ID")}): " \
            "a Gamba::Invoice computes its totals from them"
        end
        invoice = Invoice.new(**header, lines:)
        check_totals(invoice)
        invoice
      end

      private

      def header
        {
          number: text(@document, "/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:ID"),
          type: code(text(@document, "/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:TypeCode"), TYPE_CODE_BY_NAME, "type code"),
          issued_on: date(first("/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:IssueDateTime")),
          notes: all("/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:IncludedNote").map { {text: text(_1, "ram:Content"), subject: text(_1, "ram:SubjectCode")} },
          currency: text(@document, "#{SETTLEMENT}/ram:InvoiceCurrencyCode"),
          seller: party(first("#{AGREEMENT}/ram:SellerTradeParty")),
          buyer: party(first("#{AGREEMENT}/ram:BuyerTradeParty")),
          buyer_reference: text(@document, "#{AGREEMENT}/ram:BuyerReference"),
          order_reference: text(@document, "#{AGREEMENT}/ram:BuyerOrderReferencedDocument/ram:IssuerAssignedID"),
          deliver_to: delivery,
          delivered_on: date(first("#{DELIVERY}/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime")),
          **settlement
        }
      end

      def settlement
        period = first("#{SETTLEMENT}/ram:BillingSpecifiedPeriod")
        terms = one("#{SETTLEMENT}/ram:SpecifiedTradePaymentTerms", "payment terms")
        preceding = first("#{SETTLEMENT}/ram:InvoiceReferencedDocument")
        {
          payment:, period: period && (date(first("ram:StartDateTime", period))..date(first("ram:EndDateTime", period))),
          allowances: adjustments(SETTLEMENT, charge: false), charges: adjustments(SETTLEMENT, charge: true),
          payment_terms: terms && text(terms, "ram:Description"), due_on: terms && date(first("ram:DueDateDateTime", terms)),
          exemptions:, paid: decimal(text(@document, "#{SETTLEMENT}/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TotalPrepaidAmount") || "0"),
          preceding_invoice: preceding && {number: text(preceding, "ram:IssuerAssignedID"), issued_on: date(first("ram:FormattedIssueDateTime", preceding))}
        }
      end

      def line(item)
        trade_price = first("ram:SpecifiedLineTradeAgreement/ram:NetPriceProductTradePrice", item)
        basis_quantity = text(trade_price, "ram:BasisQuantity")
        quantity = first("ram:SpecifiedLineTradeDelivery/ram:BilledQuantity", item)
        line_settlement = first("ram:SpecifiedLineTradeSettlement", item)
        category, rate = tax(first("ram:ApplicableTradeTax", line_settlement))
        {
          id: text(item, "ram:AssociatedDocumentLineDocument/ram:LineID"),
          name: text(item, "ram:SpecifiedTradeProduct/ram:Name"), description: text(item, "ram:SpecifiedTradeProduct/ram:Description"),
          quantity: decimal(quantity.text), unit: quantity.attributes["unitCode"] || "C62",
          unit_price: decimal(text(trade_price, "ram:ChargeAmount")) / (basis_quantity ? decimal(basis_quantity) : 1),
          vat_category: category, vat_rate: rate,
          allowances: adjustments(line_settlement, charge: false), charges: adjustments(line_settlement, charge: true)
        }
      end

      def party(node)
        legal = first("ram:SpecifiedLegalOrganization", node)
        uri = first("ram:URIUniversalCommunication/ram:URIID", node)
        registrations = all("ram:SpecifiedTaxRegistration/ram:ID", node).to_h { [_1.attributes["schemeID"], _1.text] }
        {
          name: text(node, "ram:Name"), trading_name: legal && text(legal, "ram:TradingBusinessName"),
          legal_id: (id = legal && first("ram:ID", legal)) && {id: id.text, scheme: id.attributes["schemeID"]},
          address: address(first("ram:PostalTradeAddress", node)),
          electronic_address: uri && {id: uri.text, scheme: uri.attributes["schemeID"]},
          vat: registrations["VA"], tax_registration: registrations["FC"]
        }
      end

      def address(node)
        raise ArgumentError, "a party or delivery has no postal address, with its country" unless node

        {lines: %w[ram:LineOne ram:LineTwo ram:LineThree].filter_map { text(node, _1) }, postcode: text(node, "ram:PostcodeCode"),
         city: text(node, "ram:CityName"), country: text(node, "ram:CountryID"), subdivision: text(node, "ram:CountrySubDivisionName")}
      end

      def delivery
        party = first("#{DELIVERY}/ram:ShipToTradeParty")
        party && {name: text(party, "ram:Name"), address: address(first("ram:PostalTradeAddress", party))}
      end

      def payment
        means = one("#{SETTLEMENT}/ram:SpecifiedTradeSettlementPaymentMeans", "payment means")
        return unless means

        {
          means: code(text(means, "ram:TypeCode"), PAYMENT_MEANS_CODE_BY_NAME, "payment means code"),
          iban: text(means, "ram:PayeePartyCreditorFinancialAccount/ram:IBANID"), account_name: text(means, "ram:PayeePartyCreditorFinancialAccount/ram:AccountName"),
          bic: text(means, "ram:PayeeSpecifiedCreditorFinancialInstitution/ram:BICID"), reference: text(@document, "#{SETTLEMENT}/ram:PaymentReference")
        }
      end

      # The exemption of each category, from the VAT breakdown.
      def exemptions
        all("#{SETTLEMENT}/ram:ApplicableTradeTax").each_with_object({}) do |breakdown, exemptions|
          reason = text(breakdown, "ram:ExemptionReason")
          code = text(breakdown, "ram:ExemptionReasonCode")
          exemptions[tax(breakdown).first] = {reason:, code:} if reason || code
        end
      end

      def adjustments(parent, charge:)
        parent = first(parent) if parent.is_a?(String)
        all("ram:SpecifiedTradeAllowanceCharge", parent).filter_map do |node|
          next unless text(node, "ram:ChargeIndicator/udt:Indicator") == charge.to_s

          category, rate = tax(first("ram:CategoryTradeTax", node)) if first("ram:CategoryTradeTax", node)
          {amount: decimal(text(node, "ram:ActualAmount")), reason: text(node, "ram:Reason"), reason_code: text(node, "ram:ReasonCode"),
           vat_category: category, vat_rate: rate}
        end
      end

      def tax(node)
        category = code(text(node, "ram:CategoryCode"), VAT_CATEGORY_CODE_BY_NAME, "VAT category code")
        rate = text(node, "ram:RateApplicablePercent")
        [category, rate && decimal(rate)]
      end

      def check_totals(invoice)
        summation = first("#{SETTLEMENT}/ram:SpecifiedTradeSettlementHeaderMonetarySummation")
        stated = CHECKED_TOTALS.filter_map { |element, total| (value = text(summation, element)) && [element, decimal(value), invoice.public_send(total)] }
        tax = all("ram:TaxTotalAmount", summation).find { [nil, invoice.currency].include?(_1.attributes["currencyID"]) }
        stated << ["ram:TaxTotalAmount", decimal(tax.text), invoice.tax_total] if tax
        stated.each do |element, value, computed|
          next if value == computed

          raise ArgumentError, "the XML's #{element.delete_prefix("ram:")} is #{value.to_f}, and Gamba computes #{computed.to_f} from what it can read: " \
            "the invoice holds something Gamba::Invoice does not, or rounds otherwise than EN 16931"
        end
      end

      def code(value, names_by_name, name)
        names_by_name.key(value) || raise(ArgumentError, "#{name} #{value.inspect} is not one Gamba::Invoice holds: #{names_by_name.values.join(", ")}")
      end

      def date(node)
        return unless node

        value = text(node, "udt:DateTimeString") || text(node, "qdt:DateTimeString")
        format = first("udt:DateTimeString", node)&.attributes&.[]("format") || first("qdt:DateTimeString", node)&.attributes&.[]("format")
        raise ArgumentError, "date #{value.inspect} has format #{format.inspect}: Gamba reads 102 (YYYYMMDD)" unless format == "102" && value&.match?(/\A\d{8}\z/)

        Date.strptime(value, "%Y%m%d")
      end

      def decimal(value)
        Invoice.decimal(value.to_s.strip, "amount")
      end

      def one(path, name)
        nodes = all(path)
        raise ArgumentError, "the XML has #{nodes.size} #{name}: Gamba::Invoice holds one" if nodes.size > 1

        nodes.first
      end

      def first(path, node = @document)
        REXML::XPath.first(node, path, NAMESPACES)
      end

      def all(path, node = @document)
        REXML::XPath.match(node, path, NAMESPACES)
      end

      def text(node, path)
        value = first(path, node)&.text&.strip
        value unless value.nil? || value.empty?
      end
    end

    # The invoice the Cross Industry Invoice XML of a Factur-X or ZUGFeRD file holds, in the basic, EN 16931 or
    # extended profile.
    def self.from_xml(xml)
      XmlReader.read(xml)
    end
  end
end
