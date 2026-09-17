class Internal::HuddleController < ActionController::API
  before_action :prevent_caching
  before_action :authenticate_gateway
  before_action :ensure_huddles_configured

  def authorize
    coordinates = Huddle::TokenVerifier.new(bearer_token).coordinates
    grant = HuddleGrant.find_by(**coordinates)

    if grant&.authorize_or_revoke!
      grant.record_seen!
      render json: grant.authorization_payload
    else
      head :forbidden
    end
  rescue Huddle::TokenVerifier::Invalid
    head :unauthorized
  end

  def show
    grant = HuddleGrant.find_by(id: params[:id])

    if grant&.authorize_or_revoke!
      grant.record_seen!
      render json: grant.authorization_payload
    else
      head :not_found
    end
  end

  private
    def authenticate_gateway
      provided = request.headers["X-Huddle-Gateway-Secret"].to_s
      expected = ENV["LIVEKIT_GATEWAY_SECRET"].to_s

      head :unauthorized unless provided.present? && expected.present? &&
        ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    end

    def ensure_huddles_configured
      head :service_unavailable unless Huddle.configured?
    end

    def bearer_token
      scheme, token = request.authorization.to_s.split(" ", 2)
      raise Huddle::TokenVerifier::Invalid unless scheme&.casecmp?("Bearer") && token.present?

      token
    end

    def prevent_caching
      response.headers["Cache-Control"] = "no-store"
    end
end
