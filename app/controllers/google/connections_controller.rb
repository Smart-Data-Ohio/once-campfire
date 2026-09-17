module Google
  # Connects a member's Google account for one-way event publishing.
  # Connecting is the opt-in; disconnecting removes the connection and
  # every calendar entry the app created for the user.
  class ConnectionsController < ApplicationController
    before_action :ensure_configured

    def connect
      raw_state = SecureRandom.hex(16)
      session[:google_oauth_state] = raw_state
      redirect_to Google::Client.authorize_url(redirect_uri: google_callback_url, state: state_verifier.generate(raw_state),
          drive: drive_requested?),
        allow_other_host: true
    end

    def callback
      stored_state = session.delete(:google_oauth_state)
      verified_state = state_verifier.verified(params[:state].to_s)

      unless valid_state?(verified_state, stored_state)
        return head :unprocessable_content
      end

      if params[:error].present?
        return redirect_to user_profile_path, alert: "Google Calendar connection was not approved."
      end

      account = Current.user.google_account || Current.user.build_google_account
      tokens = Google::Client.exchange_code(code: params[:code].to_s, redirect_uri: google_callback_url)
      account.assign_attributes(
        access_token: tokens["access_token"],
        access_token_expires_at: Time.current + tokens["expires_in"].to_i.seconds,
        disconnected_reason: nil
      )
      account.refresh_token = tokens["refresh_token"] if tokens["refresh_token"].present?
      account.scopes = tokens["scope"] if tokens["scope"].present?
      account.email = Google::Client.email_from_id_token(tokens["id_token"])
      account.save!

      enqueue_upcoming_syncs(Current.user)
      redirect_to user_profile_path, notice: "Google Calendar connected."
    rescue Google::Client::Error => error
      Rails.logger.warn "Google OAuth callback failed: #{error.class}"
      redirect_to user_profile_path, alert: "Could not connect Google Calendar. Try again."
    end

    def destroy
      if (account = Current.user.google_account)
        client = Google::Client.new(account)
        Current.user.event_calendar_entries.find_each do |entry|
          begin
            client.delete_event(entry.google_event_id)
          rescue Google::Client::NotFound
            nil
          rescue StandardError => error
            Rails.logger.warn "Google Calendar disconnect could not remove entry #{entry.id}: #{error.class}"
          end
        end

        Current.user.event_calendar_entries.delete_all
        account.destroy!
      end

      redirect_to user_profile_path, notice: "Google Calendar disconnected."
    end

    private
      def ensure_configured
        head :not_found unless Google::Client.configured?
      end

      def drive_requested?
        params[:features].is_a?(Array) && params[:features].include?("drive")
      end

      def state_verifier
        Rails.application.message_verifier("google_oauth_state")
      end

      def valid_state?(verified_state, stored_state)
        verified_state.is_a?(String) && stored_state.is_a?(String) &&
          verified_state.bytesize == stored_state.bytesize &&
          Rack::Utils.secure_compare(verified_state, stored_state)
      end

      def enqueue_upcoming_syncs(user)
        EventAttendance.where(user:, response: Event::NOTIFYING_RESPONSES)
          .joins(:event).merge(Event.upcoming).pluck(:event_id).each do |event_id|
            Calendar::SyncEntryJob.perform_later(event_id, user.id)
          end
      end
  end
end
