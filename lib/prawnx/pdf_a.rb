# frozen_string_literal: true

require "time"

module Prawn
  module Errors
    PdfAViolation = Class.new(StandardError)
  end
end

module PrawnX
  # PDF/A-3b (ISO 19005-3), switched on with Prawn::Document.new(pdf_a: true): XMP metadata matching the
  # document information, an sRGB output intent, a file identifier, and errors for what PDF/A forbids.
  # Factur-X invoices (pdf.factur_x) embed their CII XML into such a document.
  module PdfA
    FACTUR_X_NAMESPACE = "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
    FACTUR_X_FILENAME = "factur-x.xml"
    # Profile names of the Factur-X specification, and the relationship it gives the XML of each (§ 6.2.2).
    FACTUR_X_LEVEL_BY_PROFILE = {
      minimum: "MINIMUM", basic_wl: "BASIC WL", basic: "BASIC", en16931: "EN 16931", extended: "EXTENDED"
    }.freeze
    RELATIONSHIP_BY_PROFILE = {
      minimum: :Data, basic_wl: :Data, basic: :Alternative, en16931: :Alternative, extended: :Alternative
    }.freeze
    # Annotation flag 3, Print: PDF/A requires printing every annotation (ISO 19005-2 §6.3.2).
    PRINT_FLAG = 4
    XMP_PROPERTY_BY_INFO_KEY = {
      Title: "dc:title", Author: "dc:creator", Subject: "dc:description", Keywords: "pdf:Keywords",
      Creator: "xmp:CreatorTool", Producer: "pdf:Producer", CreationDate: "xmp:CreateDate", ModDate: "xmp:ModifyDate"
    }.freeze

    def pdf_a?
      @pdf_a == true
    end

    def factur_x(xml, profile: :en16931, filename: FACTUR_X_FILENAME, description: "Factur-X invoice")
      raise Prawn::Errors::PdfAViolation, "Factur-X invoices are PDF/A-3 documents: create this one with pdf_a: true" unless pdf_a?

      level = FACTUR_X_LEVEL_BY_PROFILE.fetch(profile) { raise ArgumentError, "Unknown Factur-X profile #{profile.inspect}: #{FACTUR_X_LEVEL_BY_PROFILE.keys.join(", ")}" }
      @factur_x = {xml: xml.b, level:, relationship: RELATIONSHIP_BY_PROFILE.fetch(profile), filename:, description:}
    end

    private

    def finalize_pdf_a
      min_version(1.7)
      icc_profile = ref!({N: 3}, PdfA::SrgbProfile.bytes)
      @root.data[:OutputIntents] = [{
        Type: :OutputIntent, S: :GTS_PDFA1, OutputConditionIdentifier: PDF::Core::LiteralString.new(SrgbProfile::DESCRIPTION),
        Info: PDF::Core::LiteralString.new(SrgbProfile::DESCRIPTION), DestOutputProfile: icc_profile
      }]
      embed_factur_x if @factur_x
      metadata = ref!({Type: :Metadata, Subtype: :XML}, xmp_packet)
      metadata.uncompressed = true
      @root.data[:Metadata] = metadata
    end

    def embed_factur_x
      xml = @factur_x[:xml]
      modification_date = @info.data[:ModDate] || @info.data[:CreationDate]
      params = {Size: xml.bytesize}
      params[:ModDate] = modification_date if modification_date
      embedded_file = ref!({Type: :EmbeddedFile, Subtype: :"text/xml", Params: params}, xml)
      file_specification = ref!(
        Type: :Filespec, F: PDF::Core::LiteralString.new(@factur_x[:filename]), UF: @factur_x[:filename],
        Desc: @factur_x[:description], AFRelationship: @factur_x[:relationship], EF: {F: embedded_file, UF: embedded_file}
      )
      @root.data[:AF] = [file_specification]
      (names.data[:EmbeddedFiles] ||= ref!(PDF::Core::NameTree.new)).data.add(@factur_x[:filename], file_specification)
    end

    def xmp_packet
      properties = XMP_PROPERTY_BY_INFO_KEY.filter_map do |key, property|
        value = @info.data[key]
        next unless value

        text = value.is_a?(Time) ? value.iso8601 : escape_xml(value.to_s)
        case property
        when "dc:title", "dc:description" then "<#{property}><rdf:Alt><rdf:li xml:lang=\"x-default\">#{text}</rdf:li></rdf:Alt></#{property}>"
        when "dc:creator" then "<#{property}><rdf:Seq><rdf:li>#{text}</rdf:li></rdf:Seq></#{property}>"
        else "<#{property}>#{text}</#{property}>"
        end
      end
      <<~XMP
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
        <pdfaid:part>3</pdfaid:part>
        <pdfaid:conformance>B</pdfaid:conformance>
        #{properties.join("\n")}
        </rdf:Description>
        #{factur_x_xmp}
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
      XMP
    end

    # The Factur-X properties, and the PDF/A extension schema declaring them (Factur-X specification § 6.2.1).
    def factur_x_xmp
      return "" unless @factur_x

      fields = {DocumentFileName: "name of the embedded XML invoice file", DocumentType: "INVOICE",
                Version: "The actual version of the Factur-X XML schema", ConformanceLevel: "The conformance level of the embedded Factur-X data"}
      described = fields.map do |name, description|
        "<rdf:li rdf:parseType=\"Resource\"><pdfaProperty:name>#{name}</pdfaProperty:name><pdfaProperty:valueType>Text</pdfaProperty:valueType>" \
          "<pdfaProperty:category>external</pdfaProperty:category><pdfaProperty:description>#{description}</pdfaProperty:description></rdf:li>"
      end
      <<~XMP
        <rdf:Description rdf:about="" xmlns:fx="#{FACTUR_X_NAMESPACE}">
        <fx:DocumentType>INVOICE</fx:DocumentType>
        <fx:DocumentFileName>#{escape_xml(@factur_x[:filename])}</fx:DocumentFileName>
        <fx:Version>1.0</fx:Version>
        <fx:ConformanceLevel>#{@factur_x[:level]}</fx:ConformanceLevel>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
        <pdfaExtension:schemas><rdf:Bag><rdf:li rdf:parseType="Resource">
        <pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>
        <pdfaSchema:namespaceURI>#{FACTUR_X_NAMESPACE}</pdfaSchema:namespaceURI>
        <pdfaSchema:prefix>fx</pdfaSchema:prefix>
        <pdfaSchema:property><rdf:Seq>#{described.join}</rdf:Seq></pdfaSchema:property>
        </rdf:li></rdf:Bag></pdfaExtension:schemas>
        </rdf:Description>
      XMP
    end

    def escape_xml(text)
      text.encode(xml: :text)
    end
  end
end
