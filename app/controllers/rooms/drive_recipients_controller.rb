class Rooms::DriveRecipientsController < ApplicationController
  # Eligible Drive-grant recipients for the enhanced Picker review dialog
  # (JSON only). GET previews the room's current grantable members; POST
  # validate re-checks an explicit user-id selection immediately before
  # the browser calls Google, so a stale, removed, or unauthorized id is
  # rejected before any permission is granted. This is a snapshot, not
  # ongoing synchronization: future members are never added implicitly.
  #
  # Only a signed-in human with an active room membership (the same
  # audience that can post) may call these endpoints. Emails come from
  # user records; arbitrary addresses are never accepted, so there is no
  # general-purpose share-to-any-email API here.
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_share_configured
  before_action :ensure_human_requester
  before_action :ensure_not_throttled

  MAX_SELECTION = 100
  LIST_LIMIT = 60
  LIST_WINDOW = 1.minute

  # Current grantable members: active humans other than the requester,
  # with a usable email address. Ordered by name for the dialog.
  def index
    no_store_response!
    render json: { recipients: recipient_json(eligible_members) }
  end

  # Re-validates an explicit selection of user ids against current
  # membership. Every id must still be eligible; otherwise nothing is
  # returned as canonical and the client must re-preview.
  def validate
    ids = normalized_user_ids

    if ids.nil?
      return render json: { error: "invalid_recipients" }, status: :unprocessable_content
    end

    if ids.size > MAX_SELECTION
      return render json: { error: "too_many_recipients", limit: MAX_SELECTION }, status: :unprocessable_content
    end

    wanted = ids.to_set
    members = eligible_members.select { |member| wanted.include?(member.id) }.index_by(&:id)
    invalid_ids = ids - members.keys

    if invalid_ids.any?
      render json: { error: "invalid_recipients", invalid_ids: invalid_ids }, status: :unprocessable_content
    else
      no_store_response!
      render json: { recipients: recipient_json(ids.filter_map { |id| members[id] }) }
    end
  end

  private
    def request_authentication
      request.format.json? ? head(:unauthorized) : super
    end

    def ensure_share_configured
      head :not_found unless Google::Picker.configured?
    end

    # Bots, agent-backed users, and inactive accounts cannot start a
    # grant review. Bot-key and agent-token requests are already denied
    # globally; this also covers those users over a session.
    def ensure_human_requester
      user = Current.user
      head :forbidden unless user&.active? && !user.bot? && user.agent.nil?
    end

    def ensure_not_throttled
      if share_throttled?(Current.user.id)
        render json: { error: "rate_limited" }, status: :too_many_requests
      end
    end

    # Active human members other than the requester, across every login
    # method and email domain: no domain filter is applied. Agent-backed
    # users are excluded like bots. Blank or malformed emails are
    # filtered in Ruby so an unusable address never reaches Google.
    def eligible_members
      @room.users.active.without_bots.where.not(id: Current.user.id)
        .where.missing(:agent).where.not(email_address: [ nil, "" ])
        .order(Arel.sql("LOWER(users.name) ASC"), :id)
        .select { |user| user.email_address.to_s.match?(URI::MailTo::EMAIL_REGEXP) }
    end

    def recipient_json(members)
      Array(members).map do |member|
        { id: member.id, name: member.name, email: member.email_address }
      end
    end

    # nil when the key is not an array of id-like strings (a scalar or
    # an arbitrary email must never validate to an empty set).
    # Duplicates collapse; ids stay in request order.
    def normalized_user_ids
      raw = params[:user_ids]
      return nil unless raw.is_a?(Array)

      strings = raw.map { |id| id.to_s.strip }
      return nil unless strings.all? { |string| string.match?(/\A\d+\z/) }

      strings.map(&:to_i).uniq
    end

    # Per-user minute-bucketed counter shared by both actions. Null
    # stores (test env default) answer nil from increment, which counts
    # as unthrottled.
    def share_throttled?(user_id)
      key = "drive_share_recipients/#{user_id}/#{Time.current.to_i / LIST_WINDOW.to_i}"
      Rails.cache.increment(key, 1, expires_in: LIST_WINDOW).to_i > LIST_LIMIT
    end
end
