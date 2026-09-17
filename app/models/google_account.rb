# A member's connected Google account for one-way event publishing.
# Connecting is the explicit opt-in; nothing is published without a row here.
# Tokens are encrypted at rest (see active_record_encryption initializer).
class GoogleAccount < ApplicationRecord
  belongs_to :user

  encrypts :refresh_token, :access_token

  validates :user_id, uniqueness: true
  validates :email, presence: true

  # False once Google refuses a refresh with invalid_grant; the row stays so
  # the profile can offer a reconnect instead of a first-time connect.
  def connected?
    disconnected_reason.blank?
  end

  def usable?
    connected? && refresh_token.present?
  end

  def access_token_expired?
    access_token.blank? || access_token_expires_at.blank? || access_token_expires_at <= Time.current
  end

  def mark_disconnected!(reason)
    update!(disconnected_reason: reason)
  end
end
