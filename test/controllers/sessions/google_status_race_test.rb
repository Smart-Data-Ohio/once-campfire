require "test_helper"
require "timeout"

class Sessions::GoogleStatusRaceTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper
  include GoogleCalendarTestHelper

  # Separate connections must see committed rows and contend on real SQLite
  # locks. A shared fixture transaction would conceal this race.
  self.use_transactional_tests = false

  [ :deactivate, :ban ].each do |action|
    [ false, true ].each do |linked|
      test "#{action} racing #{linked ? 'linked' : 'first'} Google login leaves no usable session" do
        user = User.create!(name: "Member", email_address: "member@smartdata.net", password: "secret123456")
        if linked
          GoogleIdentity.create!(user:, subject: "race-member", email: user.email_address, domain: "smartdata.net")
        end
        state = start_google_sign_in
        original_resolve = Google::SignIn::AccountLinker.method(:resolve!)
        intervention = nil

        Google::SignIn::AccountLinker.define_singleton_method(:resolve!) do |claims|
          original_resolve.call(claims).tap do |resolved_user|
            # Interrupt precisely after eligibility was checked. A concurrent
            # administrative write either commits before session creation, or
            # encounters the callback's transaction and must run afterwards.
            intervention = Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do |connection|
                timeout = connection.select_value("PRAGMA busy_timeout").to_i
                connection.execute("PRAGMA busy_timeout = 0")
                begin
                  User.find(resolved_user.id).public_send(action)
                  :completed
                rescue ActiveRecord::StatementInvalid => error
                  raise unless error.cause.is_a?(SQLite3::BusyException)
                  :retry
                ensure
                  connection.execute("PRAGMA busy_timeout = #{timeout}")
                end
              end
            end
            Timeout.timeout(5) { intervention.join }
          end
        end

        stub_google_jwks
        stub_sign_in_code_exchange(id_token: sign_in_id_token(email: user.email_address, sub: "race-member"))
        get session_google_callback_path, params: { state:, code: "auth-code" }, env: { "REMOTE_ADDR" => "8.8.8.8" }
        user.reload.public_send(action) if intervention.value == :retry

        assert_not user.reload.active?
        assert_empty user.sessions.reload, "The callback recreated a session after #{action}"
        get root_url
        assert_redirected_to new_session_url
      ensure
        Google::SignIn::AccountLinker.define_singleton_method(:resolve!, original_resolve) if original_resolve
        intervention&.join(5)
        user&.destroy!
      end
    end
  end
end
