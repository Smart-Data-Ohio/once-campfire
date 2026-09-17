module GoogleCalendarTestHelper
  extend ActiveSupport::Concern

  GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
  GOOGLE_EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
  GOOGLE_CALENDAR_LIST_URL = "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary"

  included do
    setup :configure_google_for_test
    teardown :restore_google_config_after_test
  end

  def connect_google!(user, **attributes)
    GoogleAccount.create!(
      user:,
      email: "#{user.name.parameterize}@gmail.test",
      refresh_token: "refresh-token-#{user.id}",
      access_token: "access-token-#{user.id}",
      access_token_expires_at: 1.hour.from_now,
      **attributes
    )
  end

  def disconnect_google_env!
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")
  end

  private
    def configure_google_for_test
      @google_env_before_test = [ ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] ]
      ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
      ENV["GOOGLE_CLIENT_SECRET"] = "test-client-secret"
    end

    def restore_google_config_after_test
      ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = @google_env_before_test
    end

    def stub_google_token_refresh(access_token: "refreshed-access-token", expires_in: 3600)
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(
        status: 200,
        body: { access_token:, expires_in:, token_type: "Bearer" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_token_invalid_grant
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(
        status: 400,
        body: { error: "invalid_grant", error_description: "Token has been expired or revoked." }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_code_exchange(access_token: "new-access-token", refresh_token: "new-refresh-token")
      stub_request(:post, GOOGLE_TOKEN_URL).to_return(
        status: 200,
        body: { access_token:, refresh_token:, expires_in: 3600, token_type: "Bearer" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_event_insert(status: 200, body: {})
      stub_request(:post, GOOGLE_EVENTS_URL).to_return(
        status:, body: body.to_json, headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_event_update(google_event_id, status: 200, body: {})
      stub_request(:put, "#{GOOGLE_EVENTS_URL}/#{google_event_id}").to_return(
        status:, body: body.to_json, headers: { "Content-Type" => "application/json" }
      )
    end

    def stub_google_event_delete(google_event_id, status: 204)
      stub_request(:delete, "#{GOOGLE_EVENTS_URL}/#{google_event_id}").to_return(status:)
    end

    def stub_google_primary_calendar(email)
      stub_request(:get, GOOGLE_CALENDAR_LIST_URL).to_return(
        status: 200,
        body: { id: email, summary: email }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end
end
