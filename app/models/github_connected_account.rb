# A member's linked GitHub identity for PR write actions (comments, reviews).
# Holds a per-user fine-grained personal access token, validated against
# GET /user at link time; the token is encrypted at rest (see
# active_record_encryption initializer) and is never logged or rendered back.
class GithubConnectedAccount < ApplicationRecord
  belongs_to :user

  encrypts :access_token

  validates :user_id, uniqueness: true
  validates :github_login, presence: true

  # False once GitHub refuses the token with 401; the row stays so the
  # profile can offer a reconnect instead of a first-time connect.
  def connected?
    disconnected_reason.blank?
  end

  def usable?
    connected? && access_token.present?
  end

  def mark_disconnected!(reason)
    update!(disconnected_reason: reason)
  end
end
