class AgentEvent < ApplicationRecord
  MESSAGE_DELIVERABLE_TYPES = %w[ mention direct_message reply ].freeze
  WORK_DELIVERABLE_TYPES = %w[ work_assigned work_unassigned ].freeze
  DELIVERABLE_TYPES = (MESSAGE_DELIVERABLE_TYPES + %w[ approval_decided ] + WORK_DELIVERABLE_TYPES).freeze
  SUPPRESSED_TYPES = %w[
    delivery_suppressed_rate_limit
    delivery_suppressed_hop_limit
    delivery_suppressed_revoked
  ].freeze
  EVENT_TYPES = (DELIVERABLE_TYPES + SUPPRESSED_TYPES + %w[ posted ]).freeze

  OUTCOMES = %w[ pending delivered acknowledged suppressed ].freeze

  belongs_to :agent
  belongs_to :room, optional: true
  belongs_to :message, optional: true
  belongs_to :agent_credential, optional: true
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  scope :deliverable, -> { where(event_type: DELIVERABLE_TYPES) }
  scope :message_deliverable, -> { where(event_type: MESSAGE_DELIVERABLE_TYPES) }
  scope :ledger_only, -> { where.not(event_type: DELIVERABLE_TYPES) }
  scope :ordered, -> { order(:id) }
  scope :recent_first, -> { order(id: :desc) }

  class << self
    # Deliverable rows the agent can currently read. Message rows require
    # the message to still exist, membership in its room, and a read grant
    # covering that room (legacy agents keep read everywhere). Work rows
    # carry no message and are readable under the same rule applied to
    # their own room_id, so threads the agent can no longer read drop out
    # like revoked message rows. Approval decision rows carry no message
    # and are always readable by their own agent. Expressed as joins, the
    # way ActivityItem.accessible_to does it, so callers limit after
    # filtering and revoked rows can never hide newer readable rows.
    def readable_by(agent)
      scope = deliverable
        .joins("LEFT JOIN messages AS event_messages ON event_messages.id = agent_events.message_id")
        .joins(<<~SQL.squish)
          LEFT JOIN memberships AS event_memberships
            ON event_memberships.room_id = event_messages.room_id
            AND event_memberships.user_id = #{connection.quote(agent.user_id)}
        SQL
        .joins(<<~SQL.squish)
          LEFT JOIN memberships AS event_room_memberships
            ON event_room_memberships.room_id = agent_events.room_id
            AND event_room_memberships.user_id = #{connection.quote(agent.user_id)}
        SQL

      if agent.legacy_capabilities?
        scope.where(
          "(agent_events.event_type IN (?) AND event_messages.id IS NOT NULL AND event_memberships.id IS NOT NULL) " \
            "OR agent_events.event_type = ? " \
            "OR (agent_events.event_type IN (?) AND event_room_memberships.id IS NOT NULL)",
          MESSAGE_DELIVERABLE_TYPES, "approval_decided", WORK_DELIVERABLE_TYPES
        ).distinct
      else
        scope = scope.joins(<<~SQL.squish)
          LEFT JOIN agent_grants AS event_grants
            ON event_grants.agent_id = #{connection.quote(agent.id)}
            AND event_grants.revoked_at IS NULL
            AND event_grants.capability = #{connection.quote("read_messages")}
            AND (event_grants.room_id = event_messages.room_id OR event_grants.room_id IS NULL)
        SQL
        scope = scope.joins(<<~SQL.squish)
          LEFT JOIN agent_grants AS event_room_grants
            ON event_room_grants.agent_id = #{connection.quote(agent.id)}
            AND event_room_grants.revoked_at IS NULL
            AND event_room_grants.capability = #{connection.quote("read_messages")}
            AND (event_room_grants.room_id = agent_events.room_id OR event_room_grants.room_id IS NULL)
        SQL

        scope.where(
          "(agent_events.event_type IN (?) AND event_messages.id IS NOT NULL AND event_memberships.id IS NOT NULL AND event_grants.id IS NOT NULL) " \
            "OR agent_events.event_type = ? " \
            "OR (agent_events.event_type IN (?) AND event_room_memberships.id IS NOT NULL AND event_room_grants.id IS NOT NULL)",
          MESSAGE_DELIVERABLE_TYPES, "approval_decided", WORK_DELIVERABLE_TYPES
        ).distinct
      end
    end
  end

  def deliverable?
    DELIVERABLE_TYPES.include?(event_type)
  end

  def hop
    metadata.is_a?(Hash) ? (metadata["hop"] || 0).to_i : 0
  end

  def acknowledged!
    update!(outcome: "acknowledged") unless acknowledged?
  end

  def acknowledged?
    outcome == "acknowledged"
  end
end
