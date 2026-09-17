class Github::PullRequest < ApplicationRecord
  self.table_name = "github_pull_requests"

  STALE_AFTER = 10.minutes

  has_many :pull_request_references, class_name: "Github::PullRequestReference",
    foreign_key: :github_pull_request_id, dependent: :destroy, inverse_of: :pull_request
  has_many :messages, through: :pull_request_references
  has_many :pull_request_threads, class_name: "Github::PullRequestThread",
    foreign_key: :github_pull_request_id, dependent: :destroy, inverse_of: :pull_request

  validates :owner, :repo, presence: true
  validates :number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :number, uniqueness: { scope: %i[ owner repo ] }

  after_update_commit :broadcast_card_updates

  def full_name
    "#{owner}/#{repo}"
  end

  def stale?
    fetched_at.nil? || fetched_at < STALE_AFTER.ago
  end

  def fetch_requested_recently?
    fetch_requested_at.present? && fetch_requested_at >= STALE_AFTER.ago
  end

  # Atomically claim the right to enqueue a fetch for this PR: at most one
  # caller per PR wins per staleness window, however many renders race. The
  # update skips callbacks, so claiming never broadcasts a card update.
  def claim_fetch_request!
    return false if fetch_requested_recently?

    claimed = self.class.where(id: id)
      .where("fetch_requested_at IS NULL OR fetch_requested_at < ?", STALE_AFTER.ago)
      .update_all(fetch_requested_at: Time.current) == 1
    self.fetch_requested_at = Time.current if claimed
    claimed
  end

  # Find or create the record for a referenced PR. Safe to call concurrently:
  # a lost insert race falls back to finding the winner's row.
  def self.for_reference(owner:, repo:, number:)
    create_with(fetched_at: nil).find_or_create_by!(owner: owner, repo: repo, number: number)
  rescue ActiveRecord::RecordNotUnique
    find_by!(owner: owner, repo: repo, number: number)
  end

  def broadcast_card_updates
    referencing_messages.find_each do |message|
      Turbo::StreamsChannel.broadcast_replace_to(
        message.message_stream_target, :messages,
        target: ActionView::RecordIdentifier.dom_id(message, :github_pr_cards),
        partial: "github/pull_requests/cards",
        locals: { message: message },
        attributes: { maintain_scroll: true }
      )
    end

    pull_request_threads.includes(:channel_thread).find_each do |mapping|
      thread = mapping.channel_thread
      next if thread.nil?

      Turbo::StreamsChannel.broadcast_replace_to(
        thread, :messages,
        target: ActionView::RecordIdentifier.dom_id(thread, :github_pr_header),
        partial: "github/pull_requests/thread_header",
        locals: { thread: thread, pull_request: self },
        attributes: { maintain_scroll: true }
      )
    end
  end

  # The pull_request object carried by agent delivery payloads for mentions
  # in this PR's threads. checks_state mirrors the card's check_status.
  def agent_payload
    {
      url: html_url.presence || "https://github.com/#{full_name}/pull/#{number}",
      owner: owner,
      repo: repo,
      number: number,
      title: title,
      state: state,
      head_branch: head_branch,
      base_branch: base_branch,
      review_decision: review_decision,
      checks_state: check_status
    }
  end

  # Parsed changed-files summary: { "files" => [...], "total_count" => n }.
  # Blank or unparseable storage reads as an empty summary, never raises.
  def changed_files_summary
    parsed = changed_files.present? ? JSON.parse(changed_files) : nil
    files = parsed.is_a?(Hash) ? Array(parsed["files"]) : []
    total = parsed.is_a?(Hash) ? parsed["total_count"].to_i : 0
    { "files" => files, "total_count" => [ total, files.size ].max }
  rescue JSON::ParserError
    { "files" => [], "total_count" => 0 }
  end

  private
    def referencing_messages
      Message.where(id: pull_request_references.select(:message_id))
    end
end
