class User::InboxPreferences
  KEYS = %w[ github_review_requests agent_approvals agent_work event_reminders huddle_invitations ].freeze

  TRUE_VALUES = [ true, 1, "1", "true" ].freeze
  FALSE_VALUES = [ false, 0, "0", "false" ].freeze

  LABELS = {
    "github_review_requests" => "GitHub review requests",
    "agent_approvals" => "Agent approval requests",
    "agent_work" => "Agent work assignments",
    "event_reminders" => "Event reminders",
    "huddle_invitations" => "Huddle invitations"
  }.freeze

  DESCRIPTIONS = {
    "github_review_requests" => "Inbox items when a pull request asks for your review.",
    "agent_approvals" => "Inbox items when an agent needs your approval. Requests stay on the approvals page.",
    "agent_work" => "Inbox items for work assigned by an agent.",
    "event_reminders" => "Inbox reminders before events you are attending. Push reminders still go out.",
    "huddle_invitations" => "Inbox items for incoming huddles. The incoming-call banner still shows."
  }.freeze

  def initialize(raw)
    @values = raw.is_a?(Hash) ? raw.stringify_keys.slice(*KEYS) : {}
  end

  KEYS.each do |key|
    define_method(key) { self[key] }
    define_method("#{key}?") { self[key] }
  end

  def [](key)
    self.class.cast(@values[key.to_s], default: true)
  end

  def to_h
    KEYS.index_with { |key| self[key] }
  end

  def ==(other)
    other.is_a?(self.class) && to_h == other.to_h
  end

  class << self
    def cast(value, default: true)
      return true if TRUE_VALUES.include?(value)
      return false if FALSE_VALUES.include?(value)

      default
    end

    def boolean_value?(value)
      TRUE_VALUES.include?(value) || FALSE_VALUES.include?(value)
    end
  end
end
