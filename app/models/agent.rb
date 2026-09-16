class Agent < ApplicationRecord
  belongs_to :user
  belongs_to :owner, class_name: "User", optional: true

  enum :kind, { personal: "personal", workspace: "workspace" }, default: :personal

  validates :user_id, uniqueness: true
  validates :owner_id, presence: true, if: :personal?
  validates :owner_id, presence: true, on: :create, if: :workspace?
end
