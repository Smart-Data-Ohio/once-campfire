require "test_helper"

class PublicPolicyTest < ActiveSupport::TestCase
  ENV_VARS = %w[ LEGAL_OPERATOR_NAME LEGAL_CONTACT_EMAIL LEGAL_EFFECTIVE_DATE ].freeze

  setup do
    @original_env = ENV_VARS.to_h { |name| [ name, ENV[name] ] }
    ENV_VARS.each { |name| ENV.delete(name) }
  end

  teardown do
    @original_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "operator name is blank-friendly with no company default" do
    assert_nil PublicPolicy.operator_name

    ENV["LEGAL_OPERATOR_NAME"] = "  "
    assert_nil PublicPolicy.operator_name

    ENV["LEGAL_OPERATOR_NAME"] = "  Acme Widgets  "
    assert_equal "Acme Widgets", PublicPolicy.operator_name
  end

  test "contact email accepts valid addresses" do
    assert_nil PublicPolicy.contact_email

    ENV["LEGAL_CONTACT_EMAIL"] = " privacy@example.com "
    assert_equal "privacy@example.com", PublicPolicy.contact_email
  end

  test "contact email rejects blank and malformed values" do
    [ "", "  ", "not-an-email", "a@b", "@example.com", "a b@example.com" ].each do |value|
      ENV["LEGAL_CONTACT_EMAIL"] = value
      assert_nil PublicPolicy.contact_email, "expected nil for #{value.inspect}"
    end
  end

  test "contact email rejects header-injection and markup-breaking values" do
    [
      "privacy@example.com\nBcc: evil@example.com",
      "privacy@example.com\r\nSubject: hi",
      '"><script>alert(1)</script>',
      "privacy@example.com,other@example.com",
      "privacy@example.com;other@example.com",
      "<privacy@example.com>"
    ].each do |value|
      ENV["LEGAL_CONTACT_EMAIL"] = value
      assert_nil PublicPolicy.contact_email, "expected nil for #{value.inspect}"
    end
  end

  test "effective date is stable by default and constrained when configured" do
    assert_equal "September 18, 2026", PublicPolicy.effective_date

    ENV["LEGAL_EFFECTIVE_DATE"] = "January 2, 2027"
    assert_equal "January 2, 2027", PublicPolicy.effective_date

    ENV["LEGAL_EFFECTIVE_DATE"] = "  "
    assert_equal "September 18, 2026", PublicPolicy.effective_date

    ENV["LEGAL_EFFECTIVE_DATE"] = "<script>alert(1)</script>"
    assert_equal "September 18, 2026", PublicPolicy.effective_date

    ENV["LEGAL_EFFECTIVE_DATE"] = "x" * 41
    assert_equal "September 18, 2026", PublicPolicy.effective_date
  end
end
