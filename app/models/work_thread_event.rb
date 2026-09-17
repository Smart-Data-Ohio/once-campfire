class WorkThreadEvent < ApplicationRecord
  EVENT_TYPES = %w[ work_update work_assignment ].freeze

  belongs_to :thread, class_name: "ChannelThread", foreign_key: :channel_thread_id, inverse_of: :work_thread_events
  belongs_to :actor, class_name: "User", optional: true

  has_many :activity_items, as: :source, dependent: :destroy, inverse_of: :source

  validates :event_type, inclusion: { in: EVENT_TYPES }

  scope :ordered, -> { order(created_at: :desc, id: :desc) }

  after_create_commit :record_activity_items

  class << self
    def create_for_change!(thread:, actor:, from_status:, to_status:, from_owner:, to_owner:)
      return if from_status == to_status && from_owner&.id == to_owner&.id

      from_owner_snapshot = owner_snapshot(from_owner)
      to_owner_snapshot = owner_snapshot(to_owner)
      status_changed = from_status != to_status
      owner_changed = from_owner&.id != to_owner&.id

      create!(
        thread:,
        actor:,
        event_type: owner_changed && !status_changed ? "work_assignment" : "work_update",
        from_status:,
        to_status:,
        from_owner_id: from_owner&.id,
        to_owner_id: to_owner&.id,
        from_owner_name: from_owner&.name,
        to_owner_name: to_owner&.name,
        metadata: {
          "before" => {
            "status" => from_status,
            "owner" => from_owner_snapshot
          },
          "after" => {
            "status" => to_status,
            "owner" => to_owner_snapshot
          },
          "actor" => actor_snapshot(actor)
        }
      )
    end

    private
      def owner_snapshot(owner)
        return if owner.blank?

        {
          "id" => owner.id,
          "name" => owner.name,
          "status" => owner.status,
          "role" => owner.role
        }
      end

      def actor_snapshot(actor)
        return if actor.blank?

        {
          "id" => actor.id,
          "name" => actor.name,
          "status" => actor.status,
          "role" => actor.role
        }
      end
  end

  def status_changed?
    from_status != to_status
  end

  def owner_changed?
    from_owner_id != to_owner_id
  end

  def before_state
    {
      status: from_status,
      owner: owner_state(from_owner_id, from_owner_name)
    }
  end

  def after_state
    {
      status: to_status,
      owner: owner_state(to_owner_id, to_owner_name)
    }
  end

  # This is the contract consumed by the activity inbox. The event itself is
  # the idempotency source, so a single work mutation produces one activity
  # per currently authorized recipient even when both fields changed.
  def activity_event
    {
      event_type: event_type,
      source: self,
      source_type: self.class.base_class.name,
      source_id: id,
      thread_id: channel_thread_id,
      room_id: thread.room_id,
      actor_id: actor_id,
      recipient_user_ids: recipient_user_ids,
      before: before_state,
      after: after_state
    }
  end

  def recipient_user_ids
    room_memberships = thread.room.memberships.includes(:user).index_by(&:user_id)
    thread_memberships = thread.memberships.index_by(&:user_id)
    candidate_ids = [ thread.creator_id, from_owner_id, to_owner_id ]
    candidate_ids.concat(thread_memberships.values.select(&:involved_in_everything?).map(&:user_id))

    candidate_ids.uniq.filter_map do |user_id|
      next if user_id == actor_id

      room_membership = room_memberships[user_id]
      user = room_membership&.user
      next unless user&.active? && !user.bot?
      next if room_membership.involvement.in?(%w[ invisible nothing ])

      thread_membership = thread_memberships[user_id]
      next if thread_membership&.involved_in_nothing?

      user_id
    end
  end

  alias activity_recipient_ids recipient_user_ids

  private
    def owner_state(id, name)
      return if id.blank? && name.blank?

      { id:, name: }.compact
    end

    def record_activity_items
      return unless defined?(ActivityItems::Recorder)

      recipient_user_ids.each do |recipient_id|
        recipient = User.active.without_bots.find_by(id: recipient_id)
        next unless recipient
        next if agent_assignment_for_opted_out_recipient?(recipient)

        ActivityItems::Recorder.record!(recipient:, source: self, event_type:)
      end
    end

    # Work assigned by an agent honours the recipient's agent_work switch;
    # human-driven assignments and status updates always record.
    def agent_assignment_for_opted_out_recipient?(recipient)
      event_type == "work_assignment" && Agent.exists?(user_id: actor_id) && !recipient.inbox_preferences.agent_work
    end
end
