class Github::RepositorySubscription < ApplicationRecord
  self.table_name = "github_repository_subscriptions"

  EVENT_KEYS = %w[ opened merged closed review_requested review_submitted checks_failed ].freeze
  DEFAULT_EVENTS = %w[ opened merged review_requested checks_failed ].freeze

  # Same character rules Github::PullRequestUrl accepts for owner/repo
  # segments: word characters, dots, and dashes, excluding exactly "."
  # and "..".
  NAME_PATTERN = /\A(?!\.\.?\z)[A-Za-z0-9_.-]+\z/

  belongs_to :room
  belongs_to :created_by, class_name: "User", optional: true
  has_many :notifications, class_name: "Github::Notification",
    foreign_key: :subscription_id, dependent: :destroy, inverse_of: :subscription

  before_validation :normalize_names
  before_validation :apply_default_events, on: :create

  validates :owner, presence: true, format: { with: NAME_PATTERN }
  validates :repo, presence: true, format: { with: NAME_PATTERN }
  validates :owner, uniqueness: { scope: %i[ room_id repo ], case_sensitive: false }
  validate :events_are_known
  validates :events, presence: { message: "must include at least one event" }, on: :update
  validate :room_is_subscribable

  after_create :add_bot_to_room
  after_destroy :remove_bot_from_room_unless_subscribed

  def full_name
    "#{owner}/#{repo}"
  end

  def subscribed_to?(event_key)
    events.include?(event_key.to_s)
  end

  private
    def normalize_names
      self.owner = owner.to_s.strip.downcase
      self.repo = repo.to_s.strip.downcase
    end

    def apply_default_events
      self.events = DEFAULT_EVENTS.dup if events.blank?
    end

    def events_are_known
      unless events.is_a?(Array) && (events - EVENT_KEYS).empty?
        errors.add :events, "must be a subset of #{EVENT_KEYS.to_sentence}"
      end
    end

    def room_is_subscribable
      errors.add(:room, "must not be a direct room") if room&.direct?
    end

    def add_bot_to_room
      bot = Github::Notifier.bot_user
      room.memberships.find_or_create_by!(user: bot) do |membership|
        membership.involvement = room.default_involvement
      end
    rescue ActiveRecord::RecordNotUnique
      # Another subscription won the race to add the bot; membership exists.
    end

    def remove_bot_from_room_unless_subscribed
      return if Github::RepositorySubscription.where(room_id: room_id).exists?

      if bot = User.active_bots.find_by(name: Github::Notifier::BOT_NAME)
        Membership.where(room_id: room_id, user_id: bot.id).delete_all
      end
    end
end
