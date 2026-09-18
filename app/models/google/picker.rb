module Google
  # Browser-side Drive sharing configuration (Google Picker + Identity
  # Services token flow). All three values are public by design: the OAuth
  # web client id, the restricted browser key, and the Cloud project
  # number. No secret is read here; the server never sees the browser
  # token, and stored Calendar/metadata tokens are never rendered.
  module Picker
    class << self
      def configured?
        client_id.present? && api_key.present? && project_number.present?
      end

      def client_id
        ENV["GOOGLE_CLIENT_ID"].presence
      end

      def api_key
        ENV["GOOGLE_PICKER_API_KEY"].presence
      end

      def project_number
        ENV["GOOGLE_CLOUD_PROJECT_NUMBER"].presence
      end
    end
  end
end
