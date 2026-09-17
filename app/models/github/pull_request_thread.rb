class Github::PullRequestThread < ApplicationRecord
  self.table_name = "github_pull_request_threads"

  belongs_to :pull_request, class_name: "Github::PullRequest", foreign_key: :github_pull_request_id
  belongs_to :room
  belongs_to :channel_thread, class_name: "ChannelThread"

  validates :github_pull_request_id, uniqueness: { scope: :room_id }
  validates :channel_thread_id, uniqueness: true

  # One thread per PR per room. Safe to call concurrently: a lost insert
  # race falls back to finding the winner's row, whether the loser lost at
  # the unique index (RecordNotUnique, validations ran before the winner
  # committed) or at the uniqueness validation (RecordInvalid, the winner
  # committed first). The loser's provisional thread is destroyed so no
  # orphaned empty thread is left behind; any other error propagates.
  def self.create_or_reuse!(pull_request:, room:, channel_thread:)
    create!(pull_request: pull_request, room: room, channel_thread: channel_thread)
  rescue ActiveRecord::RecordNotUnique
    reuse_winner!(pull_request: pull_request, room: room, channel_thread: channel_thread)
  rescue ActiveRecord::RecordInvalid => error
    raise unless error.record.is_a?(Github::PullRequestThread) && lost_race_only?(error.record)

    reuse_winner!(pull_request: pull_request, room: room, channel_thread: channel_thread)
  end

  def self.reuse_winner!(pull_request:, room:, channel_thread:)
    find_by!(github_pull_request_id: pull_request.id, room_id: room.id).tap do |winner|
      channel_thread.destroy! unless winner.channel_thread_id == channel_thread.id
    end
  end
  private_class_method :reuse_winner!

  # Only a lost race qualifies for reuse: the PR-per-room uniqueness must be
  # the sole failure. Any other error alongside it (say, a thread already
  # mapped to a different PR) means the supplied thread is not a provisional
  # loser and must not be destroyed.
  def self.lost_race_only?(record)
    record.errors.attribute_names == [ :github_pull_request_id ] &&
      record.errors.where(:github_pull_request_id).all? { |error| error.type == :taken }
  end
  private_class_method :lost_race_only?

  # The pull_request object for agent delivery payloads: the PR's context
  # when the message lives in a PR thread, nil everywhere else.
  def self.payload_for_message(message)
    message.thread&.pull_request_thread&.pull_request&.agent_payload
  end
end
