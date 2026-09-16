class Github::WebhookDelivery < ApplicationRecord
  self.table_name = "github_webhook_deliveries"

  RETENTION = 7.days

  validates :delivery_guid, presence: true, uniqueness: true

  # Claim a delivery id. Returns true when this process is the first to see
  # it, false when it was already processed (a GitHub redelivery).
  def self.claim!(delivery_guid, event:)
    create!(delivery_guid: delivery_guid, event: event)
    prune_old
    true
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    false
  end

  def self.prune_old
    where(created_at: ...RETENTION.ago).delete_all
  end
end
