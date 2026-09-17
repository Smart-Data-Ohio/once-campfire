class Github::Notification < ApplicationRecord
  self.table_name = "github_notifications"

  belongs_to :subscription, class_name: "Github::RepositorySubscription", inverse_of: :notifications
  belongs_to :message, optional: true

  validates :dedupe_key, presence: true, uniqueness: { scope: :subscription_id }

  # Claim the right to post an event to a subscription. Returns the new row
  # when this process wins, nil when the event was already posted (a
  # redelivery or a repeated trigger such as a reopen). The caller sets
  # message_id after posting.
  def self.claim!(subscription:, dedupe_key:)
    create!(subscription: subscription, dedupe_key: dedupe_key)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end
end
