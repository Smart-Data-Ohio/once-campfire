class Github::PullRequest < ApplicationRecord
  self.table_name = "github_pull_requests"

  STALE_AFTER = 10.minutes

  has_many :pull_request_references, class_name: "Github::PullRequestReference",
    foreign_key: :github_pull_request_id, dependent: :destroy, inverse_of: :pull_request
  has_many :messages, through: :pull_request_references
  has_many :pull_request_threads, class_name: "Github::PullRequestThread",
    foreign_key: :github_pull_request_id, dependent: :destroy, inverse_of: :pull_request

  before_validation :normalize_repository_names

  validates :owner, :repo, presence: true
  validates :number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :number, uniqueness: { scope: %i[ owner repo ] }

  after_update_commit :broadcast_card_updates

  def full_name
    "#{owner}/#{repo}"
  end

  # Repository identity is case-insensitive: GitHub treats Smart-Data-Ohio
  # and smart-data-ohio as the same owner. Stored names are always
  # lowercase; this is the display form, keeping the fetched payload's
  # case where one was fetched.
  def display_full_name
    cased = payload&.dig("base", "repo", "full_name")
    cased = nil unless cased.is_a?(String) && cased.match?(%r{\A[^/\s]+/[^/\s]+\z})
    cased ||= html_url.to_s[%r{github\.com/([^/\s]+/[^/\s]+)}, 1]
    cased.presence || full_name
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
  # a lost insert race falls back to finding the winner's row. Names are
  # downcased so links in any case resolve to the same row.
  def self.for_reference(owner:, repo:, number:)
    owner = owner.to_s.downcase
    repo = repo.to_s.downcase
    create_with(fetched_at: nil).find_or_create_by!(owner: owner, repo: repo, number: number)
  rescue ActiveRecord::RecordNotUnique
    find_by!(owner: owner, repo: repo, number: number)
  end

  # Collapse rows that duplicate the same PR in different cases onto the
  # lowest id, then downcase every stored name. Reference and thread rows
  # pointing at a deleted duplicate are repointed at the winner; rows that
  # would collide with one the winner already has are dropped instead
  # (the winner's row already carries the same link). Runs in one
  # transaction; the downcase migration calls this.
  def self.collapse_case_duplicates!
    transaction do
      pluck(:id, :owner, :repo, :number)
        .group_by { |(_, owner, repo, number)| [ owner.to_s.downcase, repo.to_s.downcase, number ] }
        .each_value do |rows|
          next if rows.one?

          winner_id = rows.map(&:first).min
          loser_ids = rows.map(&:first) - [ winner_id ]

          Github::PullRequestReference.where(github_pull_request_id: loser_ids).find_each do |reference|
            if Github::PullRequestReference.exists?(message_id: reference.message_id, github_pull_request_id: winner_id)
              reference.delete
            else
              reference.update_columns(github_pull_request_id: winner_id)
            end
          end

          Github::PullRequestThread.where(github_pull_request_id: loser_ids).find_each do |mapping|
            if Github::PullRequestThread.exists?(github_pull_request_id: winner_id, room_id: mapping.room_id)
              mapping.delete
            else
              mapping.update_columns(github_pull_request_id: winner_id)
            end
          end

          where(id: loser_ids).delete_all
        end

      where("owner != LOWER(owner) OR repo != LOWER(repo)").update_all("owner = LOWER(owner), repo = LOWER(repo)")
    end
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
    def normalize_repository_names
      self.owner = owner.to_s.downcase
      self.repo = repo.to_s.downcase
    end

    def referencing_messages
      Message.where(id: pull_request_references.select(:message_id))
    end
end
