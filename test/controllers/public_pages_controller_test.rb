require "test_helper"

class PublicPagesControllerTest < ActionDispatch::IntegrationTest
  CRAWLER_BROWSER = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  ANCIENT_BROWSER = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/114.0"
  CURL_AGENT = "curl/8.0"

  ENV_VARS = %w[
    LEGAL_OPERATOR_NAME LEGAL_CONTACT_EMAIL LEGAL_EFFECTIVE_DATE
    GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_SIGN_IN_DOMAINS
  ].freeze

  setup do
    @original_env = ENV_VARS.to_h { |name| [ name, ENV[name] ] }
    ENV_VARS.each { |name| ENV.delete(name) }
  end

  teardown do
    @original_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "about renders signed-out with stable title and navigation" do
    get about_url

    assert_response :success
    assert_select "title", "Smartfire | About"
    assert_select "h1", "About Smartfire"
    assert_select 'nav[aria-label="Public pages"] a[href="/about"]', minimum: 1
    assert_select 'a[href="/privacy"]', minimum: 1
    assert_select 'a[href="/terms"]', minimum: 1
    assert_select 'a[href="/session/new"]', minimum: 1
    assert_match(/self-hosted/i, response.body)
  end

  test "privacy renders signed-out with Google disclosures" do
    get privacy_url

    assert_response :success
    assert_select "title", "Smartfire | Privacy Policy"
    assert_select "h1", "Privacy Policy"
    assert_match(/September 18, 2026/, response.body)
    assert_match(/openid email profile/, response.body)
    assert_match(/myaccount\.google\.com\/connections/, response.body)
    assert_match(/developers\.google\.com\/terms\/api-services-user-data-policy/, response.body)
    assert_match(/direct messages/i, response.body)
  end

  test "terms renders signed-out with software-license framing" do
    get terms_url

    assert_response :success
    assert_select "title", "Smartfire | Terms of Service"
    assert_select "h1", "Terms of Service"
    assert_match(/MIT-LICENSE/, response.body)
    assert_match(/September 18, 2026/, response.body)
  end

  test "public pages never redirect to sign-in and set no session cookie" do
    [ about_url, privacy_url, terms_url ].each do |url|
      get url

      assert_response :success, "expected success for #{url}"
      assert_no_match(/session_token/, response.headers["Set-Cookie"].to_s)
    end
  end

  test "public pages ignore the modern-browser gate, even for crawlers" do
    [ CRAWLER_BROWSER, ANCIENT_BROWSER, CURL_AGENT, "" ].each do |user_agent|
      [ about_url, privacy_url, terms_url ].each do |url|
        get url, env: { "HTTP_USER_AGENT" => user_agent }

        assert_response :success, "expected success for #{url} with #{user_agent.inspect}"
        assert_select "h1", text: /Upgrade to a supported web browser/, count: 0
      end
    end
  end

  test "public pages render without OAuth configured" do
    assert_not Google::Client.configured?
    assert_not Google::SignIn.configured?

    [ about_url, privacy_url, terms_url ].each do |url|
      get url
      assert_response :success, "expected success for #{url} without OAuth"
    end
  end

  test "public pages disclose no private state, credentials, or scripts" do
    get privacy_url
    assert_response :success

    body = response.body
    assert_no_match(/david@37signals\.com/, body)
    assert_no_match(/current-user-id/, body)
    assert_no_match(/vapid-public-key/, body)
    assert_no_match(/google-picker-client-id/, body)
    assert_no_match(/google-drive-previews/, body)
    assert_no_match(/brand-icon-names/, body)
    assert_no_match(/<script/, body)
    assert_no_match(/importmap/, body)
    assert_no_match(/action-cable|turbo-prefetch/, body)
    assert_no_match(/noindex/, body)
    assert_no_match(/csrf-token|csrf-param/, body)
  end

  test "public pages allow zoom and honor color schemes" do
    get about_url
    assert_response :success

    assert_select 'meta[name="viewport"][content="width=device-width, initial-scale=1"]'
    assert_select 'meta[name="color-scheme"][content="light dark"]'
  end

  test "non-HTML formats expose nothing" do
    get about_url(format: :json)
    assert_response :not_found

    get privacy_url(format: :json)
    assert_response :not_found

    get terms_url(format: :txt)
    assert_response :not_found

    get about_url, headers: { "Accept" => "application/json" }
    assert_response :not_found
  end

  test "wildcard Accept header receives the HTML page" do
    [ about_url, privacy_url, terms_url ].each do |url|
      get url, headers: { "Accept" => "*/*" }

      assert_response :success, "expected success for #{url} with Accept: */*"
      assert_match(/<title>Smartfire/, response.body)
    end
  end

  test "HEAD requests succeed" do
    [ about_url, privacy_url, terms_url ].each do |url|
      head url
      assert_response :success, "expected HEAD success for #{url}"
      assert_empty response.body
    end
  end

  test "unconfigured installation uses generic wording without env names" do
    get privacy_url
    assert_response :success

    assert_match(/organization hosting/i, response.body)
    assert_match(/workspace administrator/i, response.body)
    assert_no_match(/LEGAL_OPERATOR_NAME/, response.body)
    assert_no_match(/LEGAL_CONTACT_EMAIL/, response.body)
    assert_no_match(/mailto:/, response.body)
  end

  test "configured installation names the operator and contact" do
    ENV["LEGAL_OPERATOR_NAME"] = "Acme Widgets"
    ENV["LEGAL_CONTACT_EMAIL"] = "privacy@example.com"

    get privacy_url
    assert_response :success

    assert_match(/Acme Widgets/, response.body)
    assert_select 'a[href="mailto:privacy@example.com"]'

    get about_url
    assert_response :success
    assert_match(/Acme Widgets/, response.body)
  end

  test "operator name is escaped and malicious contact email is dropped" do
    ENV["LEGAL_OPERATOR_NAME"] = "<script>alert(1)</script>"
    ENV["LEGAL_CONTACT_EMAIL"] = 'privacy@example.com"><script>alert(1)</script>'

    get privacy_url
    assert_response :success

    assert_no_match(/<script>alert\(1\)<\/script>/, response.body)
    assert_match(/&lt;script&gt;alert\(1\)&lt;\/script&gt;/, response.body)
    assert_no_match(/mailto:/, response.body)
    assert_no_match(/LEGAL_CONTACT_EMAIL/, response.body)
  end

  test "sign-in page links the public pages without OAuth" do
    get new_session_url
    assert_response :success

    assert_select 'nav[aria-label="About this workspace"] a[href="/about"]'
    assert_select 'nav[aria-label="About this workspace"] a[href="/privacy"]'
    assert_select 'nav[aria-label="About this workspace"] a[href="/terms"]'
  end

  test "sign-in page keeps public links beside Google sign-in when configured" do
    Google::SignIn.stubs(:configured?).returns(true)
    Google::SignIn.stubs(:allowed_domains).returns([ "example.com" ])

    get new_session_url
    assert_response :success

    assert_match(/Sign in with Google/, response.body)
    assert_select 'nav[aria-label="About this workspace"] a[href="/about"]'
    assert_select 'nav[aria-label="About this workspace"] a[href="/privacy"]'
    assert_select 'nav[aria-label="About this workspace"] a[href="/terms"]'
  end
end
