require "net/http"

module Google
  module SignIn
    # Google's OIDC signing keys with a bounded in-memory cache. Keys
    # are fetched over TLS, cached for TTL, and refetched at most once
    # per lookup when the cache misses (Google rotates keys). Failures
    # raise Unavailable so sign-in fails closed.
    class KeyStore
      TTL = 1.hour

      @mutex = Mutex.new
      @keys = {}
      @fetched_at = nil

      class << self
        def public_key_for(kid)
          keys = cached_keys

          unless keys.key?(kid)
            keys = fetch_keys!
          end

          keys.fetch(kid) { raise SignIn::Rejected, :unknown_key }
        end

        def clear!
          @mutex.synchronize do
            @keys = {}
            @fetched_at = nil
          end
        end

        private
          def cached_keys
            fresh = @mutex.synchronize do
              @fetched_at.present? && @fetched_at > TTL.ago && @keys.any? ? @keys : nil
            end

            fresh || fetch_keys!
          end

          def fetch_keys!
            uri = URI(SignIn::JWKS_URI)
            response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
              open_timeout: Google::Client::TIMEOUT, read_timeout: Google::Client::TIMEOUT) do |http|
              http.get(uri.request_uri)
            end

            unless response.is_a?(Net::HTTPSuccess)
              raise SignIn::Unavailable, "Google key fetch failed (#{response.code})"
            end

            payload = JSON.parse(response.body.to_s)
            unless payload.is_a?(Hash) && payload["keys"].is_a?(Array)
              raise SignIn::Unavailable, "Google key fetch returned an invalid response"
            end

            keys = payload["keys"].filter_map do |jwk|
              next unless jwk.is_a?(Hash) && jwk["kty"] == "RSA" &&
                %w[ kid n e ].all? { |field| jwk[field].is_a?(String) && jwk[field].present? }

              [ jwk["kid"], rsa_from_jwk(jwk) ]
            rescue OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error, ArgumentError
              nil
            end.to_h

            raise SignIn::Unavailable, "Google key fetch returned no keys" if keys.empty?

            @mutex.synchronize do
              @keys = keys
              @fetched_at = Time.current
            end

            keys
          rescue *Google::Client::TRANSPORT_ERRORS => error
            raise SignIn::Unavailable, "Google key fetch failed (#{error.class})"
          end

          # OpenSSL 3 keys are immutable, so build the SPKI structure
          # directly instead of calling the removed set_key=.
          def rsa_from_jwk(jwk)
            public_key = OpenSSL::ASN1::Sequence([
              OpenSSL::ASN1::Integer(OpenSSL::BN.new(Base64.urlsafe_decode64(jwk["n"]), 2)),
              OpenSSL::ASN1::Integer(OpenSSL::BN.new(Base64.urlsafe_decode64(jwk["e"]), 2))
            ])
            spki = OpenSSL::ASN1::Sequence([
              OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::ObjectId("rsaEncryption"), OpenSSL::ASN1::Null(nil) ]),
              OpenSSL::ASN1::BitString(public_key.to_der)
            ])
            OpenSSL::PKey::RSA.new(spki.to_der)
          end
      end
    end
  end
end
