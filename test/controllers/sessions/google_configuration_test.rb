require "test_helper"

class Sessions::GoogleConfigurationTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  test "missing domain configuration disables Google while password login remains available" do
    ENV.delete("GOOGLE_SIGN_IN_DOMAINS")

    get new_session_url
    assert_response :success
    assert_select "form[action='#{session_google_path}']", count: 0

    post session_google_path
    assert_response :not_found
    get session_google_callback_path, params: { state: "unused", code: "unused" }
    assert_response :not_found

    post session_url, params: { email_address: users(:david).email_address, password: "secret123456" }
    assert_redirected_to root_url
    assert parsed_cookies.signed[:session_token]
  end

  test "another company can enable its own domain without application changes" do
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = "EXAMPLE.ORG"
    get new_session_url
    assert_select "p", text: /@example\.org/
    assert_select "p", text: /@smartdata\.net|@cnbssoftware\.com/, count: 0

    state = start_google_sign_in
    assert_difference "User.count", 1 do
      complete_google_sign_in(state:, email: "member@example.org", hd: "example.org", sub: "example-company-member")
    end

    assert_redirected_to root_url
    assert_predicate User.find_by!(email_address: "member@example.org"), :member?
  end

  test "removing a domain takes effect on an already started Google login" do
    state = start_google_sign_in
    ENV["GOOGLE_SIGN_IN_DOMAINS"] = "example.org"

    assert_no_difference [ "User.count", "Session.count", "GoogleIdentity.count" ] do
      complete_google_sign_in(state:, email: "alice@smartdata.net", hd: "smartdata.net")
    end

    assert_redirected_to new_session_url
  end

  test "allowed email and hosted domains can differ for secondary Workspace domains" do
    state = start_google_sign_in

    assert_difference "User.count", 1 do
      complete_google_sign_in(state:, email: "member@cnbssoftware.com", hd: "smartdata.net", sub: "secondary-domain-member")
    end

    assert_redirected_to root_url
    assert_predicate User.find_by!(email_address: "member@cnbssoftware.com"), :member?
  end
end
