class AgentApproval < ApplicationRecord
  STATUSES = %w[ pending approved denied cancelled expired ].freeze
  DECISIONS = %w[ approved denied ].freeze
  ACTION_FORMAT = /\A[a-z0-9_.-]+\z/
  PAYLOAD_MAX_BYTES = 4.kilobytes
  DEFAULT_TTL = 24.hours
  MIN_TTL = 5.minutes
  MAX_TTL = 7.days

  belongs_to :agent
  belongs_to :room, optional: true
  belongs_to :agent_credential, optional: true
  belongs_to :decided_by, class_name: "User", optional: true

  has_many :activity_items, as: :source, dependent: :destroy, inverse_of: :source

  validates :action, presence: true, length: { maximum: 60 }, format: { with: ACTION_FORMAT }
  validates :summary, presence: true, length: { maximum: 500 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validates :decision_note, length: { maximum: 200 }, allow_nil: true
  validates :external_id, uniqueness: { scope: :agent_id }, allow_nil: true
  validate :payload_size_within_limit
  validate :expires_at_within_bounds, on: :create

  before_validation :normalize_external_id, :default_expires_at, on: :create

  after_create_commit :fan_out_inbox_items

  # Lazy expiry: a stored pending row past its deadline reads as expired.
  # Every read path uses this; writers persist via #expire_if_due!.
  def effective_status
    if status == "pending" && expires_at.present? && expires_at <= Time.current
      "expired"
    else
      status
    end
  end

  def pending_effective?
    effective_status == "pending"
  end

  def expired_effective?
    effective_status == "expired"
  end

  # Persists a lazily-expired pending row. Returns true when it expired here.
  def expire_if_due!
    return false unless status == "pending" && expires_at.present? && expires_at <= Time.current

    update!(status: "expired")
    true
  end

  # Human decision. Raises ActiveRecord::RecordInvalid when the request is
  # already decided, cancelled, or expired.
  def decide!(decision:, by:, note: nil)
    decision = decision.to_s
    raise ArgumentError, "Unknown decision: #{decision}" unless DECISIONS.include?(decision)

    expire_if_due!
    unless status == "pending"
      errors.add(:base, already_settled_message)
      raise ActiveRecord::RecordInvalid.new(self)
    end

    transaction do
      update!(
        status: decision,
        decided_by: by,
        decided_at: Time.current,
        decision_note: note.presence
      )
      mark_inbox_items_handled!
      record_decision_event!
    end

    self
  end

  # Agent cancellation. Raises ActiveRecord::RecordInvalid once decided or
  # expired. Unlike a human decision, this appends no ledger event: the
  # agent already knows it cancelled.
  def cancel_by_agent!
    expire_if_due!
    unless status == "pending"
      errors.add(:base, already_settled_message)
      raise ActiveRecord::RecordInvalid.new(self)
    end

    update!(status: "cancelled")
  end

  def decidable_by?(user)
    return false unless user&.active? && !user.bot?
    return false unless agent&.user&.active?

    user.administrator? || agent.owner_id == user.id
  end

  def deciders
    admins = User.active.without_bots.where(role: :administrator).to_a
    owner = agent&.owner
    ([ owner ] + admins).compact.uniq.filter { |user| user.active? && !user.bot? }
  end

  # Contract for ActivityItems::Recorder-style checks; creation fans out
  # directly so every decider gets exactly one item.
  def activity_recipient_ids
    deciders.map(&:id)
  end

  private
    def normalize_external_id
      self.external_id = external_id.presence
    end

    def default_expires_at
      self.expires_at ||= DEFAULT_TTL.from_now
    end

    def payload_size_within_limit
      return if payload.nil?

      if payload.to_s.bytesize > PAYLOAD_MAX_BYTES
        errors.add(:payload, "is too large (maximum is 4 KB)")
      end
    end

    # The agent may request 5 minutes to 7 days. A one-minute tolerance on
    # both ends keeps exact-boundary requests from flaking as time passes
    # between assignment and validation.
    def expires_at_within_bounds
      return if expires_at.blank?

      now = Time.current
      if expires_at < (MIN_TTL.from_now(now) - 1.minute)
        errors.add(:expires_at, "must be at least 5 minutes from now")
      elsif expires_at > (MAX_TTL.from_now(now) + 1.minute)
        errors.add(:expires_at, "must be within 7 days from now")
      end
    end

    def already_settled_message
      if status == "expired"
        "Request has expired"
      else
        "Request is already #{status}"
      end
    end

    def fan_out_inbox_items
      deciders.each do |recipient|
        ActivityItem.create_or_find_by!(user: recipient, source: self) do |item|
          item.event_type = "agent_approval_request"
        end
      end
    end

    def mark_inbox_items_handled!
      now = Time.current
      activity_items.where(handled_at: nil).find_each do |item|
        item.update!(read_at: item.read_at || now, handled_at: now)
      end
    end

    def record_decision_event!
      event = agent.agent_events.create!(
        event_type: "approval_decided",
        room: room,
        actor: decided_by,
        outcome: "delivered",
        metadata: {
          "approval_id" => id,
          "status" => status,
          "decided_by" => decided_by&.name,
          "note" => decision_note
        }
      )
      post_decision_webhook!(event)
      event
    end

    def post_decision_webhook!(event)
      webhook = agent.user.webhook
      return unless webhook

      begin
        Agent::Delivery.post_approval_webhook!(webhook, self, agent: agent, delivery_id: event.id)
      rescue StandardError => error
        Rails.logger.warn "Agent approval webhook delivery #{event.id} failed: #{error.class}"
      end
    end
end
