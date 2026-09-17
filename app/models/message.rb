class Message < ApplicationRecord
  include Attachment, AgentDelivery, Broadcasts, Mentionee, Pagination, Searchable

  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }
  belongs_to :thread, class_name: "ChannelThread", optional: true, inverse_of: :messages
  belongs_to :reply_to_message, class_name: "Message", optional: true
  belongs_to :forwarded_from_message, class_name: "Message", optional: true

  has_many :boosts, dependent: :destroy
  has_many :activity_items, as: :source, dependent: :destroy, inverse_of: :source
  # This callback must run before Active Record's dependent:nullify callback. It
  # leaves a small tombstone on each reply so the UI can still explain why its
  # linked message disappeared.
  has_many :replies, class_name: "Message", foreign_key: :reply_to_message_id, dependent: :nullify
  has_many :forwards, class_name: "Message", foreign_key: :forwarded_from_message_id, dependent: :nullify

  has_one :channel_thread, class_name: "ChannelThread", foreign_key: :parent_message_id, dependent: :nullify

  has_many :github_pull_request_references, class_name: "Github::PullRequestReference", dependent: :destroy
  has_many :github_pull_requests, through: :github_pull_request_references,
    source: :pull_request, class_name: "Github::PullRequest"

  has_many :event_references, dependent: :destroy
  has_many :events, through: :event_references

  # autosave so records marked for destruction (an edit replacing the set)
  # are destroyed in the same transaction as the message save.
  has_many :drive_attachments, -> { order(:id) }, dependent: :destroy, autosave: true

  has_rich_text :body

  validates :markdown_source, length: { maximum: Markdown::SOURCE_LIMIT }, allow_nil: true
  validate :markdown_source_or_attachment, if: :markdown?
  validate :drive_attachments_within_limit

  before_validation :render_markdown_body, if: :will_save_change_to_markdown_source?
  before_create -> { self.client_message_id ||= Random.uuid } # Bots don't care
  before_destroy :preserve_reply_tombstones, prepend: true
  after_create_commit :receive_in_conversation
  after_create_commit :record_activity_items
  # Create and update need distinct callback filters: registering the same
  # method twice on the commit chain keeps only one registration.
  after_create_commit :sync_github_pull_request_references
  after_update_commit :resync_github_pull_request_references
  after_create_commit :sync_event_references
  after_update_commit :resync_event_references

  scope :ordered, -> { order(:created_at) }
  scope :root_messages, -> { where(thread_id: nil) }
  scope :thread_messages, -> { where.not(thread_id: nil) }
  scope :with_creator, -> { preload(creator: :avatar_attachment) }
  scope :with_attachment_details, -> {
    with_rich_text_body_and_embeds
      .with_attached_attachment
      .includes(attachment_blob: :variant_records)
  }
  scope :with_boosts, -> { includes(boosts: :booster) }
  # Everything messages/_message and its partials touch, so rendering a page of
  # messages costs a fixed number of queries instead of a set per message.
  # messages/_context reads the reply source's author, body and room - it links
  # to the source with message_link_url - and search results span rooms, so
  # neither :room nor anything hanging off the reply source can be assumed
  # already loaded.
  scope :with_rendering_details, -> {
    with_creator
      .with_attachment_details
      .with_boosts
      .preload(:room, :github_pull_requests, :drive_attachments, events: [ :room, :organizer, :venue ],
        reply_to_message: [ :room, :rich_text_body, { creator: :avatar_attachment } ])
  }
  # The JSON payload reads the creator, body, attachment filename, room, reply
  # source and thread, but never boosts or image variants, so it gets a lighter
  # set than the HTML partials need. The reply source needs its own room because
  # compact_message_payload builds a permalink for it.
  scope :with_payload_details, -> {
    with_creator
      .with_rich_text_body_and_embeds
      .with_attached_attachment
      .preload(:room, :thread, :channel_thread, :drive_attachments, reply_to_message: [ :room, :rich_text_body, { creator: :avatar_attachment } ])
  }

  class << self
    # The associations with_rendering_details loads, in the form
    # ActiveRecord::Associations::Preloader wants. Derived from the scope rather
    # than restated, so the two cannot drift apart.
    def rendering_associations
      relation = with_rendering_details
      relation.preload_values + relation.includes_values
    end

    # Load those associations onto records that were selected without them, so
    # that a conditional GET can answer 304 before paying for any of it.
    def preload_rendering_details(records)
      return records if records.empty?

      ActiveRecord::Associations::Preloader.new(records: records, associations: rendering_associations).call
      records
    end
  end

  # Sorting in Ruby rather than with the `ordered` scope, because applying a
  # scope to an association builds a fresh relation and so ignores the rows
  # `with_boosts` already preloaded — one extra query per message rendered.
  def ordered_boosts
    boosts.sort_by { |boost| [ boost.created_at, boost.id ] }
  end

  def plain_text_body
    text = markdown? ? Markdown.plain_text(body.body) : body.to_plain_text
    text = text.presence || attachment&.filename&.to_s || ""

    forward_note.present? ? [ forward_note, text ].compact_blank.join("\n\n") : text
  end

  def markdown?
    !markdown_source.nil?
  end

  # Messages created before the Markdown composer still have Action Text bodies.
  # The action metadata endpoint needs a source that the normal composer can
  # load, without asking the browser to scrape presentation HTML.
  def editable_markdown_source
    markdown? ? markdown_source : LegacyMarkdown.render(body.body)
  end

  # A Markdown edit replaces the Action Text body. Keep non-mention Action
  # Text attachments (for example an existing unfurl) alongside the freshly
  # rendered Markdown so a legacy edit cannot silently discard them. Mentions
  # are represented in the editable source and are re-created by the Markdown
  # renderer for the current room.
  def preserve_legacy_attachments_on_next_markdown_render!
    @legacy_attachment_snapshot = LegacyMarkdown.non_mention_attachments(body.body)
  end

  def thread_message?
    thread_id.present?
  end

  def reply?
    reply_to_message_id.present? || reply_target_deleted_at.present?
  end

  def reply_notify_author?
    reply_notify_author != false
  end

  def forwarded?
    forwarded_at.present?
  end

  def conversation
    thread || room
  end

  def message_stream_target
    conversation
  end

  def to_key
    [ client_message_id ]
  end

  def content_type
    case
    when attachment?    then "attachment"
    when sound.present? then "sound"
    else                     "text"
    end.inquiry
  end

  def sound
    plain_text_body.match(/\A\/play (?<name>\w+)\z/) do |match|
      Sound.find_by_name match[:name]
    end
  end


  private
    def record_activity_items
      ActivityItems::Recorder.record_message!(self)
    end

    def sync_github_pull_request_references
      Github::PullRequestReferenceSync.call(self)
    end

    def resync_github_pull_request_references
      Github::PullRequestReferenceSync.call(self) if saved_change_to_markdown_source?
    end

    def sync_event_references
      Event::ReferenceSync.call(self)
    end

    def resync_event_references
      Event::ReferenceSync.call(self) if saved_change_to_markdown_source?
    end

    def receive_in_conversation
      if thread
        thread.receive(self)
      else
        room.receive(self)
      end
    end

    def preserve_reply_tombstones
      replies.update_all(reply_to_message_id: nil, reply_target_deleted_at: Time.current, updated_at: Time.current)
    end

    def validate_conversation_links
      if thread && (room_id != thread.room_id || thread.room.direct?)
        errors.add :thread, "must belong to the message room and cannot be a direct room thread"
      end

      return unless reply_to_message

      source = reply_to_message
      same_stream = if thread_id.nil?
        source.thread_id.nil?
      else
        source.thread_id == thread_id || (thread && source.id == thread.parent_message_id && source.thread_id.nil?)
      end

      errors.add :reply_to_message, "must be in the same conversation" unless source.room_id == room_id && same_stream
    end

    def validate_forward_metadata
      # A source can be deleted after a forward is created. In that case the
      # database intentionally nullifies forwarded_from_message_id while the
      # forwarded_at marker remains. Only a new record needs both halves.
      return unless new_record?

      if forwarded_from_message_id.present? && forwarded_at.blank?
        errors.add :forwarded_at, "must be present for a forwarded message"
      elsif forwarded_at.present? && forwarded_from_message_id.blank?
        errors.add :forwarded_from_message, "must be present for a forwarded message"
      end
    end

    def render_markdown_body
      return unless markdown? && markdown_source.length <= Markdown::SOURCE_LIMIT

      rendered = Markdown.render(markdown_source, room:)
      self.body = [ rendered, @legacy_attachment_snapshot ].compact_blank.join("\n")
    ensure
      @legacy_attachment_snapshot = nil
    end

    def markdown_source_or_attachment
      if markdown_source.blank? && !attachment.attached? && kept_drive_attachments.empty?
        errors.add :markdown_source, "can't be blank"
      end
    end

    def drive_attachments_within_limit
      if kept_drive_attachments.size > DriveAttachment::MAX_PER_MESSAGE
        errors.add :drive_attachments, "are limited to #{DriveAttachment::MAX_PER_MESSAGE} per message"
      end
    end

    # In-memory view of the set being saved: built records count, records
    # marked for destruction do not.
    def kept_drive_attachments
      drive_attachments.reject(&:marked_for_destruction?)
    end

    validate :validate_conversation_links
    validate :validate_forward_metadata
    validates :forward_note, length: { maximum: Markdown::SOURCE_LIMIT }, allow_nil: true
end
