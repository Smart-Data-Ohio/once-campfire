# Workspace operator identity for the public About/Privacy/Terms pages.
#
# Plain config model (no database): each self-hosted installation supplies
# its own operator name and contact email through the environment. No
# company defaults are built in. When values are missing or invalid, the
# public pages render honest generic wording instead of inventing an
# operator, and document that real values must be supplied before Google
# verification or public rollout.
class PublicPolicy
  OPERATOR_NAME_ENV_VAR = "LEGAL_OPERATOR_NAME"
  CONTACT_EMAIL_ENV_VAR = "LEGAL_CONTACT_EMAIL"
  EFFECTIVE_DATE_ENV_VAR = "LEGAL_EFFECTIVE_DATE"

  DEFAULT_EFFECTIVE_DATE = "September 18, 2026"

  # Conservative address shape. Views use Rails mail_to to encode the
  # address in a URI and escape the displayed text.
  EMAIL_PATTERN = /\A[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\z/

  # Plain printable date text only; anything else falls back to the default.
  EFFECTIVE_DATE_PATTERN = /\A[[:alnum:] ,.\-]{1,40}\z/

  class << self
    def operator_name
      ENV[OPERATOR_NAME_ENV_VAR].to_s.strip.presence
    end

    def contact_email
      email = ENV[CONTACT_EMAIL_ENV_VAR].to_s.strip
      email if email.match?(EMAIL_PATTERN)
    end

    def effective_date
      raw = ENV[EFFECTIVE_DATE_ENV_VAR].to_s.strip
      raw.match?(EFFECTIVE_DATE_PATTERN) ? raw : DEFAULT_EFFECTIVE_DATE
    end
  end
end
