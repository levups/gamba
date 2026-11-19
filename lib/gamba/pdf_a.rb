# frozen_string_literal: true

require "time"

module Prawn
  module Errors
    PdfAViolation = Class.new(StandardError)
  end
end

module Gamba
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
    # XML 1.0 has no way to write these, not even as references: the XMP would not parse.
    XML_FORBIDDEN_CHARACTERS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/

    PDFUA_NAMESPACE = "http://www.aiim.org/pdfua/ns/id/"
    # pdf_a: true is PDF/A-3b, the level that keeps the look; :a adds the structure that PDF/A-3a asks for.
    CONFORMANCE_BY_OPTION = {nil => nil, false => nil, true => "B", :b => "B", :a => "A"}.freeze

    def self.conformance(option)
      CONFORMANCE_BY_OPTION.fetch(option) do
        raise ArgumentError, "pdf_a is #{option.inspect}: true or :b for PDF/A-3b, :a for PDF/A-3a"
      end
    end

    def pdf_a?
      !@pdf_a_conformance.nil?
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
    end

    # The XMP metadata PDF/A and PDF/UA both ask for, written last.
    def finalize_metadata
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
        <rdf:Description rdf:about=""#{' xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/"' if pdf_a?}#{" xmlns:pdfuaid=\"#{PDFUA_NAMESPACE}\"" if pdf_ua?} xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
        #{identification_xmp}
        #{properties.join("\n")}
        </rdf:Description>
        #{factur_x_xmp}#{extension_schemas_xmp}
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
      XMP
    end

    # The PDF/A part and level, and the PDF/UA part.
    def identification_xmp
      lines = []
      lines << "<pdfaid:part>3</pdfaid:part>" << "<pdfaid:conformance>#{@pdf_a_conformance}</pdfaid:conformance>" if pdf_a?
      lines << "<pdfuaid:part>1</pdfuaid:part>" if pdf_ua?
      lines.join("\n")
    end

    # The Factur-X properties (Factur-X specification § 6.2.1).
    def factur_x_xmp
      return "" unless @factur_x

      <<~XMP
        <rdf:Description rdf:about="" xmlns:fx="#{FACTUR_X_NAMESPACE}">
        <fx:DocumentType>INVOICE</fx:DocumentType>
        <fx:DocumentFileName>#{escape_xml(@factur_x[:filename])}</fx:DocumentFileName>
        <fx:Version>1.0</fx:Version>
        <fx:ConformanceLevel>#{@factur_x[:level]}</fx:ConformanceLevel>
        </rdf:Description>
      XMP
    end

    # PDF/A declares every schema it does not define, in one bag: Factur-X's, and PDF/UA's identification.
    def extension_schemas_xmp
      schemas = []
      if @factur_x
        fields = {DocumentFileName: "name of the embedded XML invoice file", DocumentType: "INVOICE",
                  Version: "The actual version of the Factur-X XML schema", ConformanceLevel: "The conformance level of the embedded Factur-X data"}
        schemas << extension_schema("Factur-X PDFA Extension Schema", FACTUR_X_NAMESPACE, "fx", fields.map { |name, description| [name, "Text", "external", description] })
      end
      if pdf_a? && pdf_ua?
        schemas << extension_schema("PDF/UA Universal Accessibility Schema", PDFUA_NAMESPACE, "pdfuaid",
          [["part", "Integer", "internal", "Indicates, which part of ISO 14289 standard is followed"]])
      end
      return "" if schemas.empty?

      <<~XMP
        <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
        <pdfaExtension:schemas><rdf:Bag>#{schemas.join}</rdf:Bag></pdfaExtension:schemas>
        </rdf:Description>
      XMP
    end

    def extension_schema(name, namespace, prefix, properties)
      described = properties.map do |property, type, category, description|
        "<rdf:li rdf:parseType=\"Resource\"><pdfaProperty:name>#{property}</pdfaProperty:name><pdfaProperty:valueType>#{type}</pdfaProperty:valueType>" \
          "<pdfaProperty:category>#{category}</pdfaProperty:category><pdfaProperty:description>#{description}</pdfaProperty:description></rdf:li>"
      end
      "<rdf:li rdf:parseType=\"Resource\">\n<pdfaSchema:schema>#{name}</pdfaSchema:schema>\n<pdfaSchema:namespaceURI>#{namespace}</pdfaSchema:namespaceURI>\n" \
        "<pdfaSchema:prefix>#{prefix}</pdfaSchema:prefix>\n<pdfaSchema:property><rdf:Seq>#{described.join}</rdf:Seq></pdfaSchema:property>\n</rdf:li>"
    end

    def escape_xml(text)
      text = text.encode(::Encoding::UTF_8)
      raise metadata_violation, "#{pdf_ua? ? "PDF/UA" : "PDF/A"} metadata cannot hold control characters: #{text.inspect}" if text.match?(XML_FORBIDDEN_CHARACTERS)

      text.encode(xml: :text)
    rescue EncodingError => error
      raise metadata_violation, "#{pdf_ua? ? "PDF/UA" : "PDF/A"} metadata must be text: #{error.message}"
    end

    def metadata_violation
      pdf_ua? ? Prawn::Errors::PdfUaViolation : Prawn::Errors::PdfAViolation
    end
  end
end
