module Google
  module SignIn
    # Verifies a Google OIDC id_token against Google's JWKs per
    # https://developers.google.com/identity/openid-connect/openid-connect
    # and https://developers.google.com/identity/gsi/web/guides/verify-google-id-token.
    # Returns the verified claims. Anything unexpected raises Rejected
    # (bad token) or Unavailable (Google unreachable); both fail closed.
    # This is deliberately stricter than the Calendar connection's
    # email_from_id_token, which must never serve as sign-in identity.
    class IdTokenVerifier
      class << self
        def verify!(id_token, nonce:)
          raise Rejected, :bad_token if id_token.blank? || nonce.blank?

          header = unverified_header(id_token)
          raise Rejected, :bad_token unless header["alg"] == "RS256"
          raise Rejected, :bad_token if header["kid"].blank?

          key = KeyStore.public_key_for(header["kid"].to_s)
          payload, = JWT.decode(id_token.to_s, key, true, algorithm: "RS256")
          raise Rejected, :bad_token unless payload.is_a?(Hash)

          verify_claims!(payload, nonce: nonce.to_s)
          payload
        rescue Rejected, Unavailable
          raise
        rescue JWT::DecodeError
          raise Rejected, :bad_token
        end

        private
          def unverified_header(id_token)
            _, header = JWT.decode(id_token.to_s, nil, false)
            header.is_a?(Hash) ? header : {}
          rescue JWT::DecodeError
            raise Rejected, :bad_token
          end

          def verify_claims!(payload, nonce:)
            raise Rejected, :bad_token unless payload["iss"].in?(SignIn::ISSUERS)
            verify_audience!(payload)
            verify_expiry!(payload)
            raise Rejected, :bad_token if payload["sub"].blank?
            raise Rejected, :missing_email if payload["email"].blank?
            raise Rejected, :unverified_email unless payload["email_verified"] == true
            raise Rejected, :bad_nonce unless nonce_match?(payload["nonce"], nonce)
            verify_domain!(payload)
          end

          # The audience must be this app. When several audiences are
          # present (or azp is set at all), the authorized party must
          # be this app too.
          def verify_audience!(payload)
            audiences = Array(payload["aud"]).flatten.compact.map(&:to_s)
            raise Rejected, :bad_audience unless audiences.include?(Google::Client.client_id.to_s)

            if audiences.many? || payload["azp"].present?
              raise Rejected, :bad_audience unless payload["azp"].to_s == Google::Client.client_id.to_s
            end
          end

          def verify_expiry!(payload)
            exp = payload["exp"]
            raise Rejected, :expired unless exp.is_a?(Numeric) && exp > (Time.current - SignIn::CLOCK_SKEW).to_i
          end

          # Only a verified hd organization match proves Workspace
          # membership. The email suffix alone, or an hd request hint
          # (which this flow never sends), proves nothing -- but as
          # defense in depth the email domain must be allowed too.
          def verify_domain!(payload)
            allowed = SignIn.allowed_domains
            domain = payload["hd"].to_s.strip.downcase
            email_domain = payload["email"].to_s.strip.downcase.split("@").last.to_s

            unless domain.present? && allowed.include?(domain) && allowed.include?(email_domain)
              raise Rejected, :wrong_domain
            end
          end

          def nonce_match?(actual, expected)
            actual.is_a?(String) && expected.is_a?(String) &&
              actual.bytesize == expected.bytesize &&
              ActiveSupport::SecurityUtils.secure_compare(actual, expected)
          end
      end
    end
  end
end
