class AgentCredential < ApplicationRecord
  belongs_to :agent
  belongs_to :created_by, class_name: "User"

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_last_four, presence: true

  scope :not_revoked, -> { where(revoked_at: nil) }
  scope :not_expired, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :active, -> { not_revoked.not_expired }

  class << self
    def generate_secret
      SecureRandom.hex(32)
    end

    def digest(secret)
      Digest::SHA256.hexdigest(secret.to_s)
    end

    def create_with_secret!(agent:, name:, created_by:, expires_at: nil)
      secret = generate_secret

      credential = create!(
        agent: agent,
        name: name,
        created_by: created_by,
        expires_at: expires_at,
        token_digest: digest(secret),
        token_last_four: digest(secret)[0, 4]
      )

      [ credential, secret ]
    end

    def authenticate(secret)
      return if secret.blank?

      credential = find_by(token_digest: digest(secret.strip))
      credential if credential&.active?
    end
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def active?
    !revoked? && !expired?
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end

  def record_use!(ip = nil)
    update_columns(last_used_at: Time.current, last_used_ip: ip, updated_at: Time.current)
  end
end
