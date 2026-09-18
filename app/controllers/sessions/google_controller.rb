module Sessions
  # Unauthenticated Workspace "Sign in with Google". Separate from the
  # Calendar/Drive connection flow (Google::ConnectionsController),
  # which requires login and stays opt-in: this flow requests only
  # "openid email profile" and persists no OAuth tokens.
  class GoogleController < ApplicationController
    require_unauthenticated_access only: %i[ create callback ]

    before_action :ensure_configured
    before_action :ensure_workspace_ready

    # Starts the flow: stash a browser-bound one-use state, nonce, and
    # PKCE verifier in the session, then send the browser to Google.
    def create
      verifier, challenge = Google::SignIn.pkce_pair
      raw_state = SecureRandom.hex(16)

      session[:google_sign_in_request] = {
        "state" => raw_state,
        "nonce" => SecureRandom.hex(16),
        "verifier" => verifier,
        "exp" => Google::SignIn::FLOW_TTL.from_now.to_i
      }

      redirect_to Google::SignIn.authorize_url(
        redirect_uri: session_google_callback_url,
        state: state_verifier.generate(raw_state),
        nonce: session[:google_sign_in_request]["nonce"],
        challenge:
      ), allow_other_host: true
    end

    # Handles Google's redirect back: consume the one-use flow, trade
    # the code for an id_token, verify it, and sign the user in. Every
    # failure lands back on the login page with the password form
    # intact -- Google sign-in never restricts global access.
    def callback
      flow = session.delete(:google_sign_in_request)
      verified_state = state_verifier.verified(params[:state].to_s)

      unless valid_flow?(flow, verified_state)
        return redirect_to new_session_url, alert: "Google sign-in expired. Try again or sign in with email and password."
      end

      if params[:error].present?
        return redirect_to new_session_url, alert: "Google sign-in was cancelled. Try again or sign in with email and password."
      end

      if params[:code].blank?
        return redirect_to new_session_url, alert: "Google sign-in failed. Try again or sign in with email and password."
      end

      id_token = Google::SignIn.exchange_code(
        code: params[:code].to_s,
        redirect_uri: session_google_callback_url,
        verifier: flow["verifier"]
      )
      claims = Google::SignIn::IdTokenVerifier.verify!(id_token, nonce: flow["nonce"])

      # SQLite transactions acquire the configured immediate write lock.
      # Keep eligibility, identity linking, and session insertion together:
      # deactivation/ban must either win before this check or revoke the new
      # session afterwards. All network verification stays outside the lock.
      User.transaction do
        user = Google::SignIn::AccountLinker.resolve!(claims)
        start_new_session_for user
      end
      redirect_to safe_post_authenticating_url
    rescue Google::SignIn::Unavailable
      redirect_to new_session_url, alert: "Google sign-in is unavailable right now. Try again or sign in with email and password."
    rescue Google::SignIn::Rejected => error
      Rails.logger.warn "Google sign-in rejected: #{error.reason}"
      redirect_to new_session_url, alert: rejection_alert(error.reason)
    end

    private
      def ensure_configured
        head :not_found unless Google::SignIn.configured?
      end

      # Google sign-in can only join an existing workspace; it must
      # never bypass first-run setup by provisioning its first users.
      def ensure_workspace_ready
        redirect_to first_run_url if Account.none? || User.none?
      end

      def state_verifier
        Rails.application.message_verifier("google_sign_in_state")
      end

      def valid_flow?(flow, verified_state)
        flow.is_a?(Hash) &&
          flow["state"].is_a?(String) && flow["nonce"].is_a?(String) &&
          flow["verifier"].is_a?(String) && flow["exp"].is_a?(Integer) &&
          flow["exp"] > Time.current.to_i &&
          verified_state.is_a?(String) &&
          verified_state.bytesize == flow["state"].bytesize &&
          Rack::Utils.secure_compare(verified_state, flow["state"])
      end

      def rejection_alert(reason)
        case reason
        when :wrong_domain
          "Google sign-in is only available for #{domain_list}. Other email addresses can sign in with email and password."
        when :ambiguous, :subject_mismatch
          "Google sign-in could not pick your account. Contact your administrator or sign in with email and password."
        when :deactivated, :banned
          "This account is no longer active. Contact your administrator or sign in with email and password."
        else
          "Google sign-in failed. Try again or sign in with email and password."
        end
      end

      def domain_list
        Google::SignIn.allowed_domains.map { |domain| "@#{domain}" }.to_sentence
      end

      def safe_post_authenticating_url
        Google::SignIn.safe_return_path(
          session.delete(:return_to_after_authenticating), host: request.host
        ) || root_url
      end
  end
end
