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
