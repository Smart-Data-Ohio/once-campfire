# Active Record Encryption stores Google OAuth tokens unreadably at rest.
# The keys derive from SECRET_KEY_BASE so no separate secret is needed.
# Rotating SECRET_KEY_BASE invalidates every stored token: affected users
# must reconnect their Google account (see docs/google-calendar.md).
Rails.application.config.active_record.encryption.primary_key =
  Rails.application.key_generator.generate_key("active_record_encryption/primary", 32)
Rails.application.config.active_record.encryption.deterministic_key =
  Rails.application.key_generator.generate_key("active_record_encryption/deterministic", 32)
Rails.application.config.active_record.encryption.key_derivation_salt =
  Rails.application.key_generator.generate_key("active_record_encryption/salt", 32)
