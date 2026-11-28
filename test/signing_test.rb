# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "prawn"
require_relative "support/pdf_objects"

# Signed documents, verified by Poppler's pdfsig: the whole file but the signature is signed, a changed byte
# breaks it, and the chain given travels with it.
class SigningTest < Minitest::Test
  def setup
    skip "pdfsig is not installed" unless system("pdfsig", "-v", err: File::NULL, out: File::NULL)
  end

  def test_the_whole_document_is_signed_and_verifies
    key, certificate = self_signed("Alice Martin")
    document = Prawn::Document.new { text "Contract" }
    document.sign(certificate:, key:, reason: "Approval", location: "Paris")

    report = pdfsig(document.render)

    assert_match(/Signer Certificate Common Name: Alice Martin/, report)
    assert_match(/Signature Type: adbe.pkcs7.detached/, report)
    assert_match(/Total document signed/, report)
    assert_match(/Signature Validation: Signature is Valid/, report)
  end

  def test_a_changed_byte_breaks_the_signature
    key, certificate = self_signed("Alice Martin")
    pdf = Gamba.document { |document| document.text "Pay 100 EUR" }.sign(certificate:, key:).to_s
    pdf[pdf.index("%PDF-") + 7] = "9"

    refute_match(/Signature is Valid/, pdfsig(pdf))
  end

  def test_the_chain_given_travels_with_the_signature_and_rendering_again_signs_once
    authority_key, authority = self_signed("Example CA", authority: true)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = certificate("Bob", key.public_key, authority, authority_key)
    document = Prawn::Document.new { text "Order" }
    document.sign(certificate:, key:, chain: [authority])
    document.render

    report = pdfsig(document.render)

    assert_equal 1, report.scan("Signature #").size
    assert_match(/Signature is Valid/, report)
    assert_equal 2, OpenSSL::PKCS7.new(signature_bytes(document.render)).certificates.size
  end

  def test_a_signed_form_keeps_its_fields_beside_the_signature_field
    key, certificate = self_signed("Alice Martin")
    document = Prawn::Document.new { text_field "name", at: [0, 700], width: 100, height: 20, value: "Alice" }
    document.sign(certificate:, key:)
    pdf = document.render

    assert_match(/Signature is Valid/, pdfsig(pdf))
    assert_equal %w[name Signature1], PdfObjects.new(pdf).then { |objects| objects.value(objects.catalog["/AcroForm"])["/Fields"].map { objects.value(_1)["/T"].delete_prefix("u:") } }
  end

  def test_what_cannot_sign_raises
    key, certificate = self_signed("Alice Martin")
    other_key = OpenSSL::PKey::RSA.new(2048)
    document = Prawn::Document.new

    assert_raises(ArgumentError) { document.sign(certificate: "alice.pem", key:) }
    assert_raises(ArgumentError) { document.sign(certificate:, key: other_key) }
    assert_raises(ArgumentError) { document.sign(certificate:, key:, chain: ["ca.pem"]) }
    assert_raises(ArgumentError) { Prawn::Document.new.tap { _1.encrypt_document }.sign(certificate:, key:) }
  end

  private

  def self_signed(name, authority: false)
    key = OpenSSL::PKey::RSA.new(2048)
    [key, certificate(name, key.public_key, nil, key, authority:)]
  end

  def certificate(name, public_key, issuer, issuer_key, authority: false)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = rand(1 << 32)
    certificate.subject = OpenSSL::X509::Name.parse("/CN=#{name}/O=Example")
    certificate.issuer = issuer ? issuer.subject : certificate.subject
    certificate.public_key = public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new(issuer || certificate, certificate)
    certificate.add_extension(extensions.create_extension("basicConstraints", authority ? "CA:TRUE" : "CA:FALSE", true))
    certificate.add_extension(extensions.create_extension("keyUsage", authority ? "keyCertSign" : "digitalSignature,nonRepudiation", true))
    certificate.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
    certificate
  end

  def pdfsig(pdf)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "signed.pdf")
      File.binwrite(path, pdf)
      Open3.capture2e("pdfsig", path).first
    end
  end

  def signature_bytes(pdf)
    [pdf[%r{/Contents <(\h+)>}, 1]].pack("H*").sub(/\0+\z/, "")
  end
end
