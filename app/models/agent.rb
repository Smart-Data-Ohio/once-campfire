class Agent < ApplicationRecord
  # Capabilities a legacy agent (one with zero grant rows ever created) keeps
  # in rooms it belongs to. Once any grant has ever existed, only active
  # grants count; revoking the last grant removes access.
  LEGACY_CAPABILITIES = %w[ read_messages post_messages react ].freeze

  belongs_to :user
  belongs_to :owner, class_name: "User", optional: true

  has_many :agent_credentials, dependent: :destroy
  has_many :agent_grants, dependent: :destroy
  has_many :agent_events, dependent: :destroy

  enum :kind, { personal: "personal", workspace: "workspace" }, default: :personal

  validates :user_id, uniqueness: true
  validates :owner_id, presence: true, if: :personal?
  validates :owner_id, presence: true, on: :create, if: :workspace?

  before_update -> { AgentGrant.revoke_for_agent!(self) },
    if: -> { will_save_change_to_suspended_at? && suspended_at.present? }

  def active?
    suspended_at.nil? && user&.active?
  end

  def suspended?
    suspended_at.present?
  end

  def suspend!
    update!(suspended_at: Time.current) unless suspended?
  end

  # True when no agent_grants rows exist for this agent at all, revoked or
  # not. Reads the database on every call; no caching.
  def legacy_capabilities?
    AgentGrant.where(agent_id: id).none?
  end

  # Room-scoped capability check. Reads the database on every call; no
  # caching. Room membership is checked separately by the controllers.
  def can?(capability, room = nil)
    return false unless active?

    capability = capability.to_s
    return false unless AgentGrant::CAPABILITIES.include?(capability)

    if legacy_capabilities?
      return LEGACY_CAPABILITIES.include?(capability)
    end

    room_id = case room
    when Room then room.id
    when Integer then room
    when nil then nil
    else room.try(:id)
    end
    scope = AgentGrant.active.where(agent_id: id, capability: capability)

    if room_id
      scope.where(room_id: [ room_id, nil ]).exists?
    else
      scope.where(room_id: nil).exists?
    end
  end

  # True when the agent holds the capability in any room or workspace-wide.
  # Used by endpoints without a room context (event polling). Reads the
  # database on every call; no caching.
  def has_capability_anywhere?(capability)
    return false unless active?

    capability = capability.to_s
    return false unless AgentGrant::CAPABILITIES.include?(capability)

    return LEGACY_CAPABILITIES.include?(capability) if legacy_capabilities?

    AgentGrant.active.where(agent_id: id, capability: capability).exists?
  end
end
