class AgentEvent < ApplicationRecord
  DELIVERABLE_TYPES = %w[ mention direct_message reply ].freeze
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
  scope :ledger_only, -> { where.not(event_type: DELIVERABLE_TYPES) }
  scope :ordered, -> { order(:id) }
  scope :recent_first, -> { order(id: :desc) }

  class << self
    # Deliverable rows whose message the agent can currently read: the
    # message still exists, the agent's user is a member of its room, and a
    # read grant covers that room (legacy agents keep read everywhere).
    # Expressed as joins, the way ActivityItem.accessible_to does it, so
    # callers limit after filtering and revoked rows can never hide newer
    # readable rows.
    def readable_by(agent)
      scope = deliverable
        .joins("INNER JOIN messages AS event_messages ON event_messages.id = agent_events.message_id")
        .joins(<<~SQL.squish)
          INNER JOIN memberships AS event_memberships
            ON event_memberships.room_id = event_messages.room_id
            AND event_memberships.user_id = #{connection.quote(agent.user_id)}
        SQL

      unless agent.legacy_capabilities?
        scope = scope.joins(<<~SQL.squish)
          INNER JOIN agent_grants AS event_grants
            ON event_grants.agent_id = #{connection.quote(agent.id)}
            AND event_grants.revoked_at IS NULL
            AND event_grants.capability = #{connection.quote("read_messages")}
            AND (event_grants.room_id = event_messages.room_id OR event_grants.room_id IS NULL)
        SQL
      end

      scope.distinct
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
