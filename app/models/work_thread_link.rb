class WorkThreadLink < ApplicationRecord
  KINDS = %w[ pull_request event drive_file ].freeze
  TITLE_LIMIT = 255

  enum :kind, { pull_request: "pull_request", event: "event", drive_file: "drive_file" }

  belongs_to :channel_thread
  belongs_to :github_pull_request, class_name: "Github::PullRequest", optional: true
  belongs_to :event, optional: true
  belongs_to :created_by, class_name: "User"

  validates :kind, presence: true
  validates :github_pull_request_id, uniqueness: { scope: :channel_thread_id }, if: :pull_request?
  validates :event_id, uniqueness: { scope: :channel_thread_id }, if: :event?
  validates :url, uniqueness: { scope: :channel_thread_id }, if: :drive_file?
  validate :columns_match_kind
  validate :event_in_same_room

  before_validation :truncate_title

  scope :ordered, -> { order(:id) }

  # Agent-facing link entries for a thread, in link order. Links whose
  # pull request or event row is gone carry no usable URL or title and
  # are omitted. Drive entries carry only the stored URL and cached
  # title: bots never receive Drive credentials.
  def self.agent_payloads_for(thread)
    links = if thread.association(:work_thread_links).loaded?
      thread.work_thread_links.sort_by(&:id)
    else
      where(channel_thread_id: thread.id).ordered.includes(:github_pull_request, :event).to_a
    end
    links.filter_map(&:agent_payload)
  end

  def agent_payload
    case kind
    when "pull_request" then pull_request_agent_payload
    when "event" then event_agent_payload
    when "drive_file" then drive_file_agent_payload
    end
  end

  private
    def columns_match_kind
      case kind
      when "pull_request"
        errors.add(:github_pull_request, "must be set for a pull request link") if github_pull_request_id.blank?
        errors.add(:event, "must be blank for a pull request link") if event_id.present?
        errors.add(:url, "must be blank for a pull request link") if url.present?
        errors.add(:title, "must be blank for a pull request link") if title.present?
      when "event"
        errors.add(:event, "must be set for an event link") if event_id.blank?
        errors.add(:github_pull_request, "must be blank for an event link") if github_pull_request_id.present?
        errors.add(:url, "must be blank for an event link") if url.present?
        errors.add(:title, "must be blank for an event link") if title.present?
      when "drive_file"
        errors.add(:url, "must be set for a Drive file link") if url.blank?
        errors.add(:github_pull_request, "must be blank for a Drive file link") if github_pull_request_id.present?
        errors.add(:event, "must be blank for a Drive file link") if event_id.present?
      end
    end

    def event_in_same_room
      return if event.nil? || channel_thread.nil?
      return if event.room_id == channel_thread.room_id

      errors.add(:event, "must belong to the thread's room")
    end

    def truncate_title
      self.title = title.to_s.truncate(TITLE_LIMIT) if title.present?
    end

    def pull_request_agent_payload
      pull_request = github_pull_request
      return if pull_request.nil?

      {
        kind: kind,
        url: pull_request.html_url.presence || "https://github.com/#{pull_request.full_name}/pull/#{pull_request.number}",
        title: pull_request.title,
        pull_request: pull_request.agent_payload,
        event: nil
      }
    end

    def event_agent_payload
      linked_event = event
      return if linked_event.nil?

      {
        kind: kind,
        url: routes.room_event_path(channel_thread.room_id, linked_event),
        title: linked_event.title,
        pull_request: nil,
        event: {
          id: linked_event.id,
          title: linked_event.title,
          starts_at: linked_event.starts_at&.utc,
          ends_at: linked_event.ends_at&.utc,
          cancelled: linked_event.cancelled?,
          url: routes.room_event_path(channel_thread.room_id, linked_event)
        }
      }
    end

    def drive_file_agent_payload
      { kind: kind, url: url, title: title, pull_request: nil, event: nil }
    end

    def routes
      Rails.application.routes.url_helpers
    end
end
