require "test_helper"

class Google::SignIn::KeyStoreTest < ActiveSupport::TestCase
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  test "caches keys across lookups" do
    stub_google_jwks

    first = Google::SignIn::KeyStore.public_key_for(SIGN_IN_KID)
    second = Google::SignIn::KeyStore.public_key_for(SIGN_IN_KID)

    assert_instance_of OpenSSL::PKey::RSA, first
    assert_same first, second
    assert_requested :get, GOOGLE_JWKS_URL, times: 1
  end

  test "refetches once on an unknown kid and fails closed" do
    stub_google_jwks

    error = assert_raises(Google::SignIn::Rejected) do
      Google::SignIn::KeyStore.public_key_for("unknown")
    end

    assert_equal :unknown_key, error.reason
    assert_requested :get, GOOGLE_JWKS_URL, times: 2
  end

  test "outage raises Unavailable" do
    stub_request(:get, GOOGLE_JWKS_URL).to_timeout

    assert_raises(Google::SignIn::Unavailable) do
      Google::SignIn::KeyStore.public_key_for(SIGN_IN_KID)
    end
  end

  test "non-JSON and keyless answers raise Unavailable" do
    stub_request(:get, GOOGLE_JWKS_URL).to_return(status: 200, body: "nope")

    assert_raises(Google::SignIn::Unavailable) do
      Google::SignIn::KeyStore.public_key_for(SIGN_IN_KID)
    end

    WebMock.reset!
    stub_request(:get, GOOGLE_JWKS_URL).to_return(status: 200, body: { keys: [] }.to_json)

    assert_raises(Google::SignIn::Unavailable) do
      Google::SignIn::KeyStore.public_key_for(SIGN_IN_KID)
    end
  end
end
