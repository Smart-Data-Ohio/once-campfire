class ChannelThread < ApplicationRecord
  AUTO_ARCHIVE_OPTIONS = [ 60, 1_440, 4_320, 10_080 ].freeze
  DEFAULT_AUTO_ARCHIVE_AFTER_MINUTES = 4_320
  NAME_LIMIT = 100
  WORK_STATUSES = %w[ planned in_progress blocked done ].freeze
  WORK_STATUS_LABELS = {
    "planned" => "Planned",
    "in_progress" => "In progress",
    "blocked" => "Blocked",
    "done" => "Done"
  }.freeze
  UNSET_WORK_VALUE = Object.new.freeze

  belongs_to :room
  belongs_to :creator, class_name: "User"
  belongs_to :parent_message, class_name: "Message", optional: true
  belongs_to :work_owner, class_name: "User", optional: true

  has_many :messages, -> { ordered }, foreign_key: :thread_id, inverse_of: :thread, dependent: :destroy
  has_one :pull_request_thread, class_name: "Github::PullRequestThread",
    foreign_key: :channel_thread_id, dependent: :destroy, inverse_of: :channel_thread
  has_many :memberships, class_name: "ThreadMembership", foreign_key: :thread_id, inverse_of: :thread, dependent: :destroy
  has_many :users, through: :memberships
  has_many :work_thread_events, foreign_key: :channel_thread_id, inverse_of: :thread, dependent: :destroy
  has_many :work_thread_links, foreign_key: :channel_thread_id, inverse_of: :channel_thread, dependent: :destroy

  class LockedError < StandardError; end
  class WorkUpdateForbidden < StandardError; end

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :auto_archive_after_minutes, inclusion: { in: AUTO_ARCHIVE_OPTIONS }
  validates :work_status, inclusion: { in: WORK_STATUSES, allow_nil: true }
  validate :work_owner_requires_work
  validate :work_owner_must_be_eligible, if: :work_owner_assignment_changed?
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
  scope :work, -> { where.not(work_status: nil) }
  scope :unfinished_work, -> { where(work_status: WORK_STATUSES - [ "done" ]) }
  scope :for_room_member, ->(user) {
    if user&.active? && !user.bot?
      joins(room: :memberships).where(memberships: { user_id: user.id }).distinct
    else
      none
    end
  }

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

  def work?
    work_status.present?
  end

  def work_status_label
    WORK_STATUS_LABELS.fetch(work_status, work_status.to_s.humanize)
  end

  def work_owner_active?
    owner = work_owner
    return false if owner.blank?
    return agent_work_owner_eligible?(owner) if owner.bot?

    owner.active? && room.memberships.exists?(user_id: owner.id)
  end

  # A bot user owns work when it has an Agent row that is active, belongs
  # to the parent room, and may post there. Suspending the agent or
  # revoking its membership reads exactly like an inactive human owner:
  # the assignment stays visible as unavailable, with no unassign path.
  def agent_work_owner_eligible?(user)
    return false unless room.present? && user&.bot?

    agent = user.agent || Agent.find_by(user_id: user.id)
    agent.present? && agent.active? && room.memberships.exists?(user_id: user.id) && agent.can?(:post_messages, room)
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

  # Work metadata follows room access, while the existing thread lifecycle
  # continues to use its own moderator rules. A current owner may move work
  # through statuses; assignment and conversion remain manager operations.
  def work_viewable_by?(user)
    user&.active? && !user.bot? && room.memberships.exists?(user_id: user.id)
  end

  def work_manageable_by?(user)
    work_viewable_by?(user) && (settings_manageable_by?(user) || work_owner_id == user.id)
  end

  def work_status_manageable_by?(user)
    work_manageable_by?(user)
  end

  def work_assignment_manageable_by?(user)
    work_viewable_by?(user) && settings_manageable_by?(user)
  end

  def work_conversion_manageable_by?(user)
    work_assignment_manageable_by?(user)
  end

  # Update work fields in one row-locked transaction and append one durable
  # event for the complete before/after state. The sentinel distinguishes an
  # omitted field from an explicit nil used to clear an assignment or remove
  # work tracking. When an agent becomes or stops being the owner, its
  # work_assigned or work_unassigned ledger row is written in the same
  # transaction; the webhook goes out after, like approval decisions.
  def update_work!(actor:, work_status: UNSET_WORK_VALUE, work_owner_id: UNSET_WORK_VALUE)
    requested_status = work_status
    requested_owner_id = work_owner_id
    assignment_events = []

    self.class.transaction(requires_new: true) do
      with_lock do
        reload
        raise WorkUpdateForbidden, "You cannot manage work in this thread" unless work_manageable_by?(actor)

        before_status = self.work_status
        before_owner = self.work_owner
        after_status = requested_status.equal?(UNSET_WORK_VALUE) ? before_status : normalize_work_status(requested_status)
        after_owner_id = requested_owner_id.equal?(UNSET_WORK_VALUE) ? self.work_owner_id : normalize_work_owner_id(requested_owner_id)

        if requested_owner_id != UNSET_WORK_VALUE && !work_assignment_manageable_by?(actor)
          raise WorkUpdateForbidden, "Only a thread manager can assign work"
        end

        if before_status.present? != after_status.present? && !work_conversion_manageable_by?(actor)
          raise WorkUpdateForbidden, "Only a thread manager can start or stop work tracking"
        end

        validate_work_update!(status: after_status, owner_id: after_owner_id)
        changed = before_status != after_status || self.work_owner_id != after_owner_id
        if changed
          update!(work_status: after_status, work_owner_id: after_owner_id)
          association(:work_owner).reset
          WorkThreadEvent.create_for_change!(
            thread: self,
            actor: actor,
            from_status: before_status,
            to_status: after_status,
            from_owner: before_owner,
            to_owner: work_owner
          )
          assignment_events = record_work_assignment_events!(from_owner: before_owner, to_owner: work_owner, actor: actor)
        end
      end
    end

    # The controller may wrap this call in its own transaction; the webhook
    # must not hold the SQLite write lock or describe work that rolls back.
    ActiveRecord.after_all_transactions_commit { deliver_work_assignment_webhooks(assignment_events) }

    self
  end

  # Status update by the owning agent through the Bearer [REDACTED] API. The agent must
  # already own this work; reassignment, conversion, and untracking stay
  # human operations. Records a WorkThreadEvent with the agent's user as
  # actor, so the inbox path is identical to a human owner's update. The
  # manage_threads grant is checked by the controller, which owns the 403.
  def update_work_status_by_agent!(agent:, work_status:, note: nil)
    normalized_status = work_status.to_s.presence
    unless WORK_STATUSES.include?(normalized_status)
      errors.add(:work_status, "is invalid")
      raise ActiveRecord::RecordInvalid.new(self)
    end

    normalized_note = note.to_s.presence
    if normalized_note && normalized_note.length > 500
      errors.add(:base, "Note is too long (maximum is 500 characters)")
      raise ActiveRecord::RecordInvalid.new(self)
    end

    self.class.transaction(requires_new: true) do
      with_lock do
        reload
        unless work? && work_owner_id == agent.user_id
          raise ActiveRecord::RecordNotFound, "Work thread is not owned by this agent"
        end

        before_status = self.work_status
        if before_status != normalized_status
          update!(work_status: normalized_status)
          WorkThreadEvent.create_for_change!(
            thread: self,
            actor: agent.user,
            from_status: before_status,
            to_status: normalized_status,
            from_owner: work_owner,
            to_owner: work_owner,
            note: normalized_note
          )
        end
      end
    end

    self
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

    def work_owner_requires_work
      return if work_owner_id.blank? || work_status.present?

      errors.add :work_owner, "requires work tracking"
    end

    def work_owner_assignment_changed?
      will_save_change_to_work_owner_id? && work_owner_id.present?
    end

    def work_owner_must_be_eligible
      owner = User.find_by(id: work_owner_id)

      if owner&.bot?
        return if agent_work_owner_eligible?(owner)

        errors.add :work_owner, "must be an active agent member of the parent room with permission to post"
        return
      end

      return if owner&.active? && room&.memberships&.exists?(user_id: owner.id)

      errors.add :work_owner, "must be an active human member of the parent room"
    end

    def normalize_work_status(value)
      normalized = value.to_s.presence
      return normalized if normalized.nil? || WORK_STATUSES.include?(normalized)

      errors.add(:work_status, "is invalid")
      raise ActiveRecord::RecordInvalid.new(self)
    end

    def normalize_work_owner_id(value)
      return value.id if value.is_a?(User)
      return if value.blank?

      Integer(value, exception: false).tap do |normalized|
        if normalized.nil?
          errors.add(:work_owner, "is invalid")
          raise ActiveRecord::RecordInvalid.new(self)
        end
      end
    end

    def validate_work_update!(status:, owner_id:)
      if owner_id.present? && status.blank?
        errors.add(:work_owner, "requires work tracking")
      end
      return unless errors.any?

      raise ActiveRecord::RecordInvalid.new(self)
    end

    # Ledger rows for the agents affected by an owner change. Runs inside
    # the caller's locked transaction, on the reloaded row: the previous
    # agent owner (if any) gets work_unassigned and the new agent owner
    # (if any) gets work_assigned. Status-only changes notify nobody.
    # Bots without an Agent row have no ledger to write to and are
    # skipped. Returns the created rows for webhook delivery after the
    # transaction commits.
    def record_work_assignment_events!(from_owner:, to_owner:, actor:)
      return [] if from_owner&.id == to_owner&.id

      events = []
      if (previous_agent = agent_for_work_owner(from_owner))
        events << previous_agent.agent_events.create!(
          event_type: "work_unassigned",
          room: room,
          actor: actor,
          outcome: "delivered",
          metadata: {
            "thread_id" => id,
            "title" => name,
            "work_status" => work_status,
            "assigned_by" => actor&.name
          }
        )
      end
      if (next_agent = agent_for_work_owner(to_owner))
        events << next_agent.agent_events.create!(
          event_type: "work_assigned",
          room: room,
          actor: actor,
          outcome: "delivered",
          metadata: {
            "thread_id" => id,
            "title" => name,
            "work_status" => work_status,
            "assigned_by" => actor&.name
          }
        )
      end
      events
    end

    def agent_for_work_owner(owner)
      return unless owner&.bot?

      owner.agent || Agent.find_by(user_id: owner.id)
    end

    # Posts assignment webhooks after the outermost transaction commits.
    # Gated on current room membership plus read_messages like message
    # delivery: an agent removed from the room learns nothing more about
    # its work there, even if a workspace-wide grant survives.
    def deliver_work_assignment_webhooks(events)
      events.each do |event|
        agent = event.agent
        next unless Membership.exists?(user_id: agent.user_id, room_id: room_id) && agent.can?(:read_messages, room)

        webhook = agent.user.webhook
        next unless webhook

        begin
          Agent::Delivery.post_work_webhook!(webhook, event, thread: self, agent: agent)
        rescue StandardError => error
          Rails.logger.warn "Agent work webhook delivery #{event.id} failed: #{error.class}"
        end
      end
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
