class User < ApplicationRecord
  include Avatar, Bannable, Bot, Mentionable, Role, Transferable

  has_many :memberships, dependent: :delete_all
  has_many :rooms, through: :memberships

  has_many :reachable_messages, through: :rooms, source: :messages
  has_many :messages, dependent: :destroy, foreign_key: :creator_id
  has_many :channel_threads, dependent: :destroy, foreign_key: :creator_id
  has_many :thread_memberships, class_name: "ThreadMembership", dependent: :destroy
  has_many :followed_threads, through: :thread_memberships, source: :thread

  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all

  has_one :google_account, dependent: :destroy
  has_many :event_calendar_entries, dependent: :destroy

  has_many :boosts, dependent: :destroy, foreign_key: :booster_id
  has_many :searches, dependent: :delete_all

  has_many :sessions, dependent: :destroy
  has_many :workspace_presence_leases, dependent: :delete_all
  has_many :bans, dependent: :destroy

  enum :status, %i[ active deactivated banned ], default: :active

  normalizes :github_login, with: ->(login) { login.to_s.strip.downcase.presence }

  validates :github_login, uniqueness: { case_sensitive: false, message: "is already linked to another user" }, allow_nil: true
  validate :inbox_preferences_must_be_boolean

  before_update -> { HuddleGrant.revoke_for_user!(self) }, if: -> { will_save_change_to_status? && !active? }
  before_destroy -> { HuddleGrant.revoke_for_user!(self) }, prepend: true
  before_update -> { AgentGrant.revoke_for_user!(self) }, if: -> { will_save_change_to_status? && !active? }
  before_destroy -> { AgentGrant.revoke_for_user!(self) }, prepend: true

  has_secure_password validations: false

  # Users whose memberships are managed explicitly (like the GitHub bot)
  # skip the automatic open-room grant at creation.
  attr_accessor :skip_open_room_grant

  after_create_commit :grant_membership_to_open_rooms, unless: :skip_open_room_grant

  scope :ordered, -> { order("LOWER(name)") }
  scope :filtered_by, ->(query) { where("name like ?", "%#{query}%") }

  # Per-integration inbox switches. Missing keys read as true so existing
  # users keep today's behavior; only explicit false suppresses an item.
  def inbox_preferences
    User::InboxPreferences.new(self[:inbox_preferences])
  end

  def inbox_preferences=(value)
    hash = value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : value.to_h
    self[:inbox_preferences] = hash.stringify_keys.slice(*User::InboxPreferences::KEYS)
  end

  def initials
    name.scan(/\b\w/).join
  end

  def title
    [ name, bio ].compact_blank.join(" – ")
  end

  def deactivate
    calendar_event_ids = nil

    transaction do
      close_remote_connections

      # delete_all skips the membership hook, so capture the entries now
      # for cleanup syncs after commit.
      calendar_event_ids = event_calendar_entries.pluck(:event_id)
      memberships.without_direct_rooms.delete_all
      push_subscriptions.delete_all
      searches.delete_all
      sessions.delete_all
      google_account&.mark_disconnected!("Account deactivated")

      update! status: :deactivated, email_address: deactived_email_address
    end

    calendar_event_ids.each { |event_id| Calendar::SyncEntryJob.perform_later(event_id, id) }
  end

  def reset_remote_connections
    close_remote_connections reconnect: true
  end

  private
    def inbox_preferences_must_be_boolean
      (self[:inbox_preferences] || {}).each do |key, value|
        unless User::InboxPreferences.boolean_value?(value)
          errors.add(:"inbox_preferences.#{key}", "must be true or false")
        end
      end
    end

    def grant_membership_to_open_rooms
      Membership.insert_all(Rooms::Open.pluck(:id).collect { |room_id| { room_id: room_id, user_id: id } })
    end

    def deactived_email_address
      email_address&.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def close_remote_connections(reconnect: false)
      ActionCable.server.remote_connections.where(current_user: self).disconnect reconnect: reconnect
    end
end
