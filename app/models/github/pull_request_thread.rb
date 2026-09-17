class Github::PullRequestThread < ApplicationRecord
  self.table_name = "github_pull_request_threads"

  belongs_to :pull_request, class_name: "Github::PullRequest", foreign_key: :github_pull_request_id
  belongs_to :room
  belongs_to :channel_thread, class_name: "ChannelThread"

  validates :github_pull_request_id, uniqueness: { scope: :room_id }
  validates :channel_thread_id, uniqueness: true

  # One thread per PR per room. Safe to call concurrently: a lost insert
  # race falls back to finding the winner's row.
  def self.create_or_reuse!(pull_request:, room:, channel_thread:)
    create!(pull_request: pull_request, room: room, channel_thread: channel_thread)
  rescue ActiveRecord::RecordNotUnique
    find_by!(github_pull_request_id: pull_request.id, room_id: room.id)
  end

  # The pull_request object for agent delivery payloads: the PR's context
  # when the message lives in a PR thread, nil everywhere else.
  def self.payload_for_message(message)
    message.thread&.pull_request_thread&.pull_request&.agent_payload
  end
end
