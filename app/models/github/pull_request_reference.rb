class Github::PullRequestReference < ApplicationRecord
  self.table_name = "github_pull_request_references"

  belongs_to :message
  belongs_to :pull_request, class_name: "Github::PullRequest", foreign_key: :github_pull_request_id

  validates :github_pull_request_id, uniqueness: { scope: :message_id }
end
