class Twitter::PostReference < ApplicationRecord
  self.table_name = "twitter_post_references"

  belongs_to :message
  belongs_to :post, class_name: "Twitter::Post", foreign_key: :twitter_post_id

  validates :twitter_post_id, uniqueness: { scope: :message_id }
end
