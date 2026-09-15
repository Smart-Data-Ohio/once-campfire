class HuddleCleanup < ApplicationRecord
  ENQUEUE_LEASE = 1.minute
  INITIAL_RETRY_DELAY = 15.seconds
  MAX_RETRY_DELAY = 15.minutes

  belongs_to :huddle_grant, optional: true

  enum :operation, %w[ remove_participant delete_room ].index_by(&:itself)

  scope :pending, -> { where(completed_at: nil) }
  scope :due, -> {
    pending.where(next_attempt_at: nil).or(pending.where(next_attempt_at: ..Time.current))
  }

  validates :room_name, presence: true
  validates :identity, presence: true, if: :remove_participant?

  after_create_commit :enqueue_later

  class << self
    def create_participant_removal!(grant)
      find_or_create_by!(operation: :remove_participant, huddle_grant_id: grant.id) do |cleanup|
        cleanup.room_name = grant.room_name
        cleanup.identity = grant.identity
      end
    end

    def create_room_deletion!(room_name)
      find_or_create_by!(operation: :delete_room, room_name: room_name)
    end

    def reconcile_now(limit: 100)
      return 0 unless Huddle.livekit_admin_configured?

      due.order(:id).limit(limit).pluck(:id).count do |id|
        find_by(id: id)&.perform!
      rescue => error
        Rails.logger.error "Unexpected huddle cleanup failure #{id}: #{error.class}"
        false
      end
    end
  end

  def enqueue_later
    return false unless Huddle.livekit_admin_configured?

    claimed_at = Time.current

    claimed = with_lock do
      next false unless completed_at.nil? && enqueued_at.nil? && due?

      update_columns(enqueued_at: claimed_at, next_attempt_at: ENQUEUE_LEASE.from_now)
      true
    end
    return false unless claimed

    Huddle::CleanupJob.perform_later(id)
    true
  rescue => error
    with_lock do
      update_columns(enqueued_at: nil, next_attempt_at: nil) if completed_at.nil? && enqueued_at.present?
    end
    Rails.logger.warn "Could not enqueue huddle cleanup #{id}: #{error.class}"
    false
  end

  def perform_from_queue!
    perform!(from_queue: true)
  end

  def perform!(from_queue: false)
    return false unless Huddle.livekit_admin_configured?

    claimed = with_lock do
      next false if completed? || (from_queue ? enqueued_at.nil? : !due?)

      attempt = attempts + 1
      now = Time.current
      update_columns(
        attempts: attempt,
        enqueued_at: nil,
        last_attempted_at: now,
        next_attempt_at: now + retry_delay(attempt)
      )
      true
    end
    return false unless claimed

    case operation
    when "remove_participant"
      Huddle::RoomService.new.remove_participant(room_name: room_name, identity: identity)
    when "delete_room"
      Huddle::RoomService.new.delete_room(room_name: room_name)
    end

    update!(completed_at: Time.current, next_attempt_at: nil)
    true
  rescue Huddle::ServerError => error
    Rails.logger.warn "Huddle cleanup #{id} failed on attempt #{attempts}: #{error.code || error.status || error.class}"
    false
  end

  def completed?
    completed_at.present?
  end

  private
    def due?
      next_attempt_at.nil? || next_attempt_at <= Time.current
    end

    def retry_delay(attempt)
      [ INITIAL_RETRY_DELAY * (2**(attempt - 1)), MAX_RETRY_DELAY ].min
    end
end
