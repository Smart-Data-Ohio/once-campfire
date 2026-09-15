class ChannelThread < ApplicationRecord
  AUTO_ARCHIVE_OPTIONS = [ 60, 1_440, 4_320, 10_080 ].freeze
  DEFAULT_AUTO_ARCHIVE_AFTER_MINUTES = 4_320
  NAME_LIMIT = 100

  belongs_to :room
  belongs_to :creator, class_name: "User"
  belongs_to :parent_message, class_name: "Message", optional: true

  has_many :messages, -> { ordered }, foreign_key: :thread_id, inverse_of: :thread, dependent: :destroy
  has_many :memberships, class_name: "ThreadMembership", foreign_key: :thread_id, inverse_of: :thread, dependent: :destroy
  has_many :users, through: :memberships

  class LockedError < StandardError; end

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :auto_archive_after_minutes, inclusion: { in: AUTO_ARCHIVE_OPTIONS }
  validate :room_cannot_be_direct
  validate :parent_message_belongs_to_room

  before_validation :set_default_name, on: :create
  before_validation :set_default_last_activity_at, on: :create

  scope :ordered, -> { order(last_activity_at: :desc, id: :desc) }
  scope :active, -> { where(closed_at: nil, locked_at: nil) }
  # Discord presents locked threads with closed threads in the normal closed
  # view. A separate locked scope remains available for moderation tooling.
  scope :closed, -> { where.not(closed_at: nil) }
  scope :locked, -> { where.not(locked_at: nil) }
  scope :not_deleted, -> { all }

  class << self
    # There is no scheduled-job facility in this Campfire deployment. Expire
    # stale conversations whenever the thread surface is consulted, and take a
    # row lock for the final decision so a concurrent post always wins.
    def close_stale_in(room: nil)
      scope = room ? room.channel_threads : all
      scope.active.find_each(&:close_if_stale!)
    end
  end

  def status
    return "locked" if locked_at.present?
    return "closed" if closed_at.present?

    "active"
  end

  def active?
    status == "active"
  end

  def closed?
    status == "closed"
  end

  def locked?
    status == "locked"
  end

  def auto_archive_at
    last_activity_at + auto_archive_after_minutes.minutes
  end

  def stale?
    active? && auto_archive_at <= Time.current
  end

  def close_if_stale!(expected_last_activity_at: nil)
    with_lock do
      reload
      return self if expected_last_activity_at && last_activity_at != expected_last_activity_at

      update!(closed_at: Time.current) if stale?
    end
    self
  end

  def reopen!
    with_lock do
      reload
      update!(closed_at: nil) if closed? && !locked?
    end
    self
  end

  def close!
    with_lock do
      reload
      update!(closed_at: Time.current) unless locked? || closed?
    end
    self
  end

  # Keep lifecycle names separate from Active Record's lock! row-lock helper.
  # Callers that need a row lock should use with_lock; this method changes the
  # conversation's user-visible lifecycle state.
  def lock_conversation!
    with_lock do
      reload
      now = Time.current
      update!(closed_at: closed_at || now, locked_at: locked_at || now)
    end
    self
  end

  def unlock_conversation!
    with_lock do
      reload
      update!(locked_at: nil, closed_at: nil)
    end
    self
  end

  # The membership, lifecycle transition, activity timestamp, and post belong
  # to one critical section. In particular, a close/lock racing a post may not
  # leave a newly written message in a thread that was just archived or locked.
  def post_message!(creator:, attributes:)
    message = nil

    self.class.transaction(requires_new: true) do
      with_lock do
        reload
        raise LockedError, "This thread is locked" if locked?

        ensure_parent_membership!(creator)
        ThreadMembership.join!(self, creator)
        now = Time.current
        update!(closed_at: nil, last_activity_at: now)
        message = Message.create_with_attachment!(attributes.merge(room:, thread: self, creator:))
      end
    end

    message
  end

  def manageable_by?(user)
    user&.administrator? || user&.id == room.creator_id
  end

  def settings_manageable_by?(user)
    manageable_by?(user) || user&.id == creator_id
  end

  def lifecycle_manageable_by?(user)
    manageable_by?(user)
  end

  def creator_or_manager?(user)
    settings_manageable_by?(user)
  end

  def message_count
    messages.count
  end

  def unread_for?(user)
    memberships.find_by(user_id: user.id)&.unread?
  end

  def membership_for(user)
    memberships.find_by(user_id: user.id)
  end

  def receive(message)
    unread_user_ids = mark_memberships_unread(message)
    broadcast_unread_threads(unread_user_ids)
    ChannelThread::PushMessageJob.perform_later(self, message)
  end

  private
    def set_default_name
      return if name.present?

      source = parent_message&.plain_text_body.to_s.lines.first.to_s.strip
      self.name = source.truncate(NAME_LIMIT, omission: "…").presence || "New thread"
    end

    def set_default_last_activity_at
      self.last_activity_at ||= Time.current
    end

    def room_cannot_be_direct
      errors.add :room, "can't be a direct room" if room&.direct?
    end

    def parent_message_belongs_to_room
      return if parent_message.blank? || (parent_message.room_id == room_id && parent_message.thread_id.nil?)

      errors.add :parent_message, "must be a root message in the parent room"
    end

    def mark_memberships_unread(message)
      unread_user_ids = []

      memberships.where.not(user_id: message.creator_id).find_each do |membership|
        next unless room.memberships.exists?(user_id: membership.user_id)

        # Thread unread state means that a followed conversation changed. It is
        # deliberately independent from notification preference, which the
        # pusher evaluates separately for each recipient.
        membership.update_columns(unread_at: message.created_at, updated_at: Time.current)
        unread_user_ids << membership.user_id
      end

      unread_user_ids
    end

    def broadcast_unread_threads(user_ids)
      user_ids.uniq.each do |user_id|
        ActionCable.server.broadcast UnreadThreadsChannel.stream_name_for(user_id), { threadId: id, roomId: room_id }
      end
    end

    def ensure_parent_membership!(user)
      Membership.lock.find_by!(room:, user:)
    end
end
