require "test_helper"

class Sessions::GoogleResponsesTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  test "malformed JSON structures from the token endpoint return to password sign-in" do
    [ nil, [], 42, "unexpected", { id_token: [] }, { id_token: {} } ].each do |payload|
      state = start_google_sign_in
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(status: 200, body: payload.to_json)

      assert_no_difference [ "User.count", "Session.count", "GoogleIdentity.count" ] do
        get session_google_callback_path, params: { state:, code: "auth-code" }
      end

      assert_redirected_to new_session_url
      follow_redirect!
      assert_select ".flash", text: /Try again or sign in with email and password/
      WebMock.reset!
    end
  end

  test "malformed JSON structures from the key endpoint return a retry message" do
    [ nil, [], 42, { keys: nil }, { keys: "unexpected" }, { keys: [ nil, 42, "invalid", { kty: "RSA", kid: [], n: {}, e: 42 } ] } ].each do |payload|
      state = start_google_sign_in
      stub_sign_in_code_exchange
      stub_request(:get, GOOGLE_JWKS_URL).to_return(status: 200, body: payload.to_json)

      assert_no_difference [ "User.count", "Session.count", "GoogleIdentity.count" ] do
        get session_google_callback_path, params: { state:, code: "auth-code" }
      end

      assert_redirected_to new_session_url
      follow_redirect!
      assert_select ".flash", text: /unavailable right now/
      WebMock.reset!
    end
  end
end
