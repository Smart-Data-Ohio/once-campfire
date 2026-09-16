class Github::PullRequest < ApplicationRecord
  self.table_name = "github_pull_requests"

  STALE_AFTER = 10.minutes

  STATES = %w[ open draft merged closed ].freeze
  REVIEW_DECISIONS = %w[ approved changes_requested review_required ].freeze
  CHECK_STATUSES = %w[ passing pending failing ].freeze

  has_many :pull_request_references, class_name: "Github::PullRequestReference",
    foreign_key: :github_pull_request_id, dependent: :destroy, inverse_of: :pull_request
  has_many :messages, through: :pull_request_references

  validates :owner, :repo, presence: true
  validates :number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :number, uniqueness: { scope: %i[ owner repo ] }

  after_update_commit :broadcast_card_updates

  scope :stale, -> { where(fetched_at: nil).or(where(fetched_at: ...STALE_AFTER.ago)) }

  def full_name
    "#{owner}/#{repo}"
  end

  def stale?
    fetched_at.nil? || fetched_at < STALE_AFTER.ago
  end

  def loaded?
    fetched_at.present? && fetch_error.nil?
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
  end

  private
    def referencing_messages
      Message.where(id: pull_request_references.select(:message_id))
    end
end
