# frozen_string_literal: true

require "openssl"

module Gamba
  # A digital signature over the whole document (ISO 32000-1 §12.8): a PKCS#7 detached signature of every byte but
  # its own, in an invisible signature field of the first page, as Acrobat and Poppler verify it. The signature is
  # computed once the file is written, in the room reserved for it.
  module Signing
    # Room for the DER signature, certificates included: a chain of three 4096-bit certificates takes about 6 KB.
    SIGNATURE_BYTES = 16_384
    BYTE_RANGE_PLACEHOLDER = [0, 9_999_999_999, 9_999_999_999, 9_999_999_999].freeze
    # Annotation flags Print and Locked.
    SIGNATURE_WIDGET_FLAGS = 4 | 128
    # Signatures exist, and the file is to be saved by appending to it (ISO 32000-1 table 219).
    SIGNATURES_EXIST_APPEND_ONLY = 3

    # Signs the document when it is rendered, with certificate (OpenSSL::X509::Certificate) and its private key;
    # chain holds the intermediate certificates to include. reason, location and contact are shown by viewers.
    def sign(certificate:, key:, chain: [], reason: nil, location: nil, contact: nil, signed_at: Time.now)
      raise ArgumentError, "certificate is #{certificate.class}: give an OpenSSL::X509::Certificate" unless certificate.is_a?(OpenSSL::X509::Certificate)
      raise ArgumentError, "key is #{key.class}: give the certificate's OpenSSL::PKey" unless key.is_a?(OpenSSL::PKey::PKey)
      raise ArgumentError, "key is not the certificate's private key" unless certificate.check_private_key(key)
      raise ArgumentError, "chain: give an Array of OpenSSL::X509::Certificates" unless chain.is_a?(Array) && chain.all?(OpenSSL::X509::Certificate)
      raise ArgumentError, "signed_at is #{signed_at.inspect}: give a Time" unless signed_at.is_a?(Time)
      raise ArgumentError, "Gamba does not sign encrypted documents yet: sign it, or encrypt it, not both" if @encryption
      raise tagging_violation, "#{tagging_standard} tags signature fields as Form elements, which Gamba does not do yet" if tagged?

      @signing = {certificate:, key:, chain:, reason:, location:, contact:, signed_at:}
      self
    end

    private

    # The signature dictionary, its placeholders filled once the file is written, and its field on the first page.
    def prepare_signature
      raise ArgumentError, "Gamba does not sign encrypted documents yet: sign it, or encrypt it, not both" if @encryption
      raise ArgumentError, "a document to sign needs a page" if pages.empty?

      @signature_reference ||= begin
        signing = @signing
        value = {Type: :Sig, Filter: :"Adobe.PPKLite", SubFilter: :"adbe.pkcs7.detached", ByteRange: BYTE_RANGE_PLACEHOLDER.dup,
                 Contents: PDF::Core::ByteString.new("\0".b * SIGNATURE_BYTES), M: signing[:signed_at]}
        common_name = signing[:certificate].subject.to_a.find { _1.first == "CN" }&.at(1)
        value[:Name] = signature_text(common_name) if common_name
        value[:Reason] = signature_text(signing[:reason]) if signing[:reason]
        value[:Location] = signature_text(signing[:location]) if signing[:location]
        value[:ContactInfo] = signature_text(signing[:contact]) if signing[:contact]
        signature = ref!(value)
        first_page = pages.first.dictionary
        widget = ref!(Type: :Annot, Subtype: :Widget, FT: :Sig, T: PDF::Core::LiteralString.new("Signature1"), V: signature, Rect: [0, 0, 0, 0],
          F: SIGNATURE_WIDGET_FLAGS, P: first_page)
        (first_page.data[:Annots] ||= []) << widget
        form = (@root.data[:AcroForm] ||= ref!(Fields: [])).data
        (form[:Fields] ||= []) << widget
        form[:SigFlags] = SIGNATURES_EXIST_APPEND_ONLY
        signature
      end
    end

    def signature_text(text)
      text = text.to_s
      text.ascii_only? ? PDF::Core::LiteralString.new(text) : PDF::Core::ByteString.new("\xFE\xFF".b + text.encode(::Encoding::UTF_16BE).b)
    end

    # The byte range around the signature's hexadecimal string, then the signature of those bytes in its place.
    def sign_written(pdf)
      object = pdf.index("\n#{@signature_reference.identifier} 0 obj\n") || raise(Prawn::Errors::MalformedPDF, "the signature dictionary was not written")
      placeholder = PDF::Core.serialize(BYTE_RANGE_PLACEHOLDER)
      range_at = pdf.index(placeholder, object)
      contents_at = pdf.index("/Contents <", object) + "/Contents ".bytesize
      contents_end = contents_at + (2 * SIGNATURE_BYTES) + 2
      byte_range = [0, contents_at, contents_end, pdf.bytesize - contents_end]
      pdf[range_at, placeholder.bytesize] = fit_byte_range(byte_range, placeholder.bytesize)
      signed = pdf.byteslice(0, contents_at) + pdf.byteslice(contents_end, pdf.bytesize - contents_end)
      signing = @signing
      der = OpenSSL::PKCS7.sign(signing[:certificate], signing[:key], signed, signing[:chain], OpenSSL::PKCS7::DETACHED | OpenSSL::PKCS7::BINARY).to_der
      raise ArgumentError, "the signature takes #{der.bytesize} bytes, more than the #{SIGNATURE_BYTES} reserved: a shorter chain" if der.bytesize > SIGNATURE_BYTES

      pdf[contents_at + 1, der.bytesize * 2] = der.unpack1("H*")
      pdf
    end

    # The byte range as an array of the placeholder's width, padded with spaces before its bracket.
    def fit_byte_range(byte_range, width)
      text = "[#{byte_range.join(" ")}"
      raise ArgumentError, "the document is too large to sign: 10 GB at most" if text.bytesize >= width

      "#{text.ljust(width - 1)}]"
    end
  end
end
