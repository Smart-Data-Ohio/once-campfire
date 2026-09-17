class Agents::ApprovalsController < ApplicationController
  allow_agent_access only: %i[ index show create destroy for_agent ]
  allow_bot_access only: %i[ for_agent ]

  before_action :ensure_agent_token, only: %i[ index show create destroy ]
  before_action :set_own_approval, only: %i[ show destroy ]

  POLL_MAX_LIMIT = 100
  HTML_PER_PAGE = 50

  # GET /agents/approvals?status=pending (Bearer-only, JSON). Lists the
  # agent's own rows, newest first, max 100.
  def index
    no_store_response!

    agent = Current.agent
    unless agent.has_capability_anywhere?(:external_action)
      render json: { error: "Forbidden: agent lacks external_action capability" }, status: :forbidden
      return
    end

    status_filter = params[:status].presence_in(AgentApproval::STATUSES)
    scope = AgentApproval.where(agent_id: agent.id).order(id: :desc)
    scope = apply_effective_status_filter(scope, status_filter) if status_filter
    approvals = scope.limit(POLL_MAX_LIMIT).includes(:room, :decided_by).to_a
    approvals.each(&:expire_if_due!)

    # Re-filter pending after lazy expiry so expired rows never read as pending.
    if status_filter == "pending"
      approvals.select!(&:pending_effective?)
    elsif status_filter == "expired"
      approvals.select!(&:expired_effective?)
    end

    render json: approvals.map { |approval| approval_payload(approval) }
  end

  # GET /agents/approvals/:id (Bearer-only, JSON).
  def show
    no_store_response!

    unless capability_for_approval?(@approval)
      render json: { error: "Forbidden: agent lacks external_action capability" }, status: :forbidden
      return
    end

    @approval.expire_if_due!
    render json: approval_payload(@approval)
  end

  # POST /agents/approvals (Bearer-only, JSON). A repeated external_id
  # returns the existing row with 200 instead of a duplicate.
  def create
    no_store_response!

    agent = Current.agent
    fields = approval_request_fields
    room = find_request_room(fields["room_id"])
    return if performed?

    unless agent.can?(:external_action, room)
      render json: { error: "Forbidden: agent lacks external_action capability" }, status: :forbidden
      return
    end

    if fields["external_id"].present?
      existing = AgentApproval.where(agent_id: agent.id, external_id: fields["external_id"]).first
      if existing
        existing.expire_if_due!
        render json: approval_created_payload(existing), status: :ok
        return
      end
    end

    # github.* approvals carry an executable payload the server built and
    # bound to the summary the decider sees; they are only created through
    # the pull-request actions endpoint, never with agent-supplied payloads.
    if fields["action"].to_s.start_with?("github.")
      render json: { error: "github.* actions are requested through /rooms/:room_id/agents/github/pull_request_actions" },
        status: :unprocessable_entity
      return
    end

    approval = AgentApproval.new(
      agent: agent,
      room: room,
      agent_credential: current_credential,
      action: fields["action"],
      summary: fields["summary"],
      payload: serialize_payload(fields["payload"]),
      external_id: fields["external_id"],
      expires_at: resolve_expires_at(fields)
    )

    if approval.save
      render json: approval_created_payload(approval), status: :created
    else
      render json: { error: approval.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # Two identical requests raced past the replay lookup; the loser
    # answers with the winner's row exactly like a replay.
    existing = AgentApproval.find_by!(agent_id: agent.id, external_id: fields["external_id"])
    existing.expire_if_due!
    render json: approval_created_payload(existing), status: :ok
  rescue ArgumentError => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  # DELETE /agents/approvals/:id (Bearer-only, JSON). Cancels a pending
  # request; 422 once decided or expired.
  def destroy
    no_store_response!

    unless capability_for_approval?(@approval)
      render json: { error: "Forbidden: agent lacks external_action capability" }, status: :forbidden
      return
    end

    begin
      @approval.cancel_by_agent!
    rescue ActiveRecord::RecordInvalid
      render json: { error: @approval.errors.full_messages.to_sentence.presence || "Request cannot be cancelled" }, status: :unprocessable_entity
      return
    end

    render json: approval_payload(@approval)
  end

  # GET /agents/:id/approvals (HTML). Approval history for admins and the
  # agent's owner. Paginated, filterable by status. Bearer agent tokens
  # and non-deciders get 404.
  def for_agent
    if authenticated_by.agent_token? || authenticated_by.bot_key? || Current.user&.bot?
      head :not_found
      return
    end

    @agent = Agent.find_by(id: params[:id])
    @bot = @agent&.user
    unless @agent && @bot && decider?(@agent, Current.user)
      head :not_found
      return
    end

    @status_filter = params[:status].presence_in(AgentApproval::STATUSES)
    @page = [ params[:page].to_i, 1 ].max

    scope = AgentApproval.where(agent_id: @agent.id).order(id: :desc).includes(:room, :decided_by)
    scope = apply_effective_status_filter(scope, @status_filter) if @status_filter

    @approvals = scope.limit(HTML_PER_PAGE + 1).offset((@page - 1) * HTML_PER_PAGE).to_a
    @approvals.each(&:expire_if_due!)
    if @status_filter == "pending"
      @approvals.select!(&:pending_effective?)
    elsif @status_filter == "expired"
      @approvals.select!(&:expired_effective?)
    end
    @has_next = @approvals.size > HTML_PER_PAGE
    @approvals.pop if @has_next
  end

  private
    def ensure_agent_token
      unless authenticated_by.agent_token? && Current.agent
        render json: { error: "Forbidden: Bearer agent token required" }, status: :forbidden
      end
    end

    def set_own_approval
      @approval = AgentApproval.where(agent_id: Current.agent.id).includes(:room, :decided_by).find_by(id: params[:id])
      head :not_found unless @approval
    end

    def capability_for_approval?(approval)
      Current.agent.can?(:external_action, approval.room)
    end

    def decider?(agent, user)
      return false unless user&.active? && !user.bot?
      return false unless agent.user&.active?

      user.administrator? || agent.owner_id == user.id
    end

    # Effective-status filter in SQL so the limit applies after filtering.
    # Pending means stored pending with a future deadline; expired means
    # stored expired or stored pending past its deadline.
    def apply_effective_status_filter(scope, status)
      case status
      when "pending"
        scope.where(status: "pending").where("expires_at > ?", Time.current)
      when "expired"
        scope.where("status = ? OR (status = ? AND expires_at <= ?)", "expired", "pending", Time.current)
      else
        scope.where(status: status)
      end
    end

    # Accepts a nested approval object or top-level fields. Top-level
    # `action` collides with the routing param, so the raw body is read
    # for it and `approval_action` works as an alias.
    def approval_request_fields
      nested = params[:approval]
      nested_hash = case nested
      when ActionController::Parameters then nested.to_unsafe_h
      when Hash then nested
      else {}
      end
      nested_hash = nested_hash.transform_keys(&:to_s) if nested_hash.any?

      body_params = request.request_parameters
      body_hash = body_params.is_a?(Hash) ? body_params : {}

      payload = if nested_hash.key?("payload")
        nested_value(nested, "payload")
      elsif body_hash.key?("payload")
        body_hash["payload"]
      else
        params[:payload]
      end

      {
        "action" => nested_hash["action"].presence || body_hash["action"].presence || params[:approval_action].presence,
        "summary" => nested_hash["summary"].presence || params[:summary].presence || body_hash["summary"].presence,
        "room_id" => nested_hash["room_id"].presence || params[:room_id].presence || body_hash["room_id"].presence,
        "payload" => payload,
        "external_id" => nested_hash["external_id"].presence || params[:external_id].presence || body_hash["external_id"].presence,
        "expires_at" => nested_hash["expires_at"].presence || params[:expires_at].presence || body_hash["expires_at"].presence,
        "expires_in" => nested_hash["expires_in"].presence || nested_hash["expires_in_seconds"].presence ||
          params[:expires_in].presence || params[:expires_in_seconds].presence ||
          body_hash["expires_in"].presence || body_hash["expires_in_seconds"].presence
      }
    end

    def nested_value(nested, key)
      if nested.is_a?(ActionController::Parameters)
        nested.key?(key) ? nested[key] : nil
      elsif nested.is_a?(Hash)
        nested[key] || nested[key.to_sym]
      end
    end

    def find_request_room(room_id)
      return nil if room_id.blank?

      room = Room.find_by(id: room_id)
      unless room && Membership.exists?(user_id: Current.agent.user_id, room_id: room.id)
        head :not_found
        return nil
      end

      room
    end

    def current_credential
      scheme, token = request.authorization.to_s.split(" ", 2)
      return nil unless scheme&.casecmp?("Bearer") && token.present?

      AgentCredential.find_by(token_digest: AgentCredential.digest(token.strip))
    end

    def serialize_payload(payload)
      case payload
      when nil then nil
      when String then payload
      when ActionController::Parameters then payload.to_unsafe_h.to_json
      when Hash, Array then payload.to_json
      else payload.to_s
      end
    end

    def resolve_expires_at(fields)
      if fields["expires_in"].present?
        seconds = Integer(fields["expires_in"], exception: false)
        raise ArgumentError, "Invalid expires_in" if seconds.nil?

        seconds.seconds.from_now
      elsif fields["expires_at"].present?
        parsed = Time.zone.parse(fields["expires_at"].to_s)
        raise ArgumentError, "Invalid expires_at" if parsed.nil?

        parsed
      end
    end

    def approval_created_payload(approval)
      {
        id: approval.id,
        status: approval.effective_status,
        expires_at: approval.expires_at&.utc
      }.compact
    end

    def approval_payload(approval)
      decided_by_name = approval.decided_by&.name
      {
        id: approval.id,
        action: approval.action,
        summary: approval.summary,
        payload: parse_stored_payload(approval.payload),
        room_id: approval.room_id,
        room_name: approval.room&.name,
        external_id: approval.external_id,
        status: approval.effective_status,
        expires_at: approval.expires_at&.utc,
        created_at: approval.created_at&.utc,
        decided_by: decided_by_name,
        decided_by_id: approval.decided_by_id,
        decided_at: approval.decided_at&.utc,
        decision_note: approval.decision_note,
        note: approval.decision_note
      }.compact
    end

    def parse_stored_payload(stored)
      return nil if stored.nil?

      JSON.parse(stored)
    rescue JSON::ParserError
      stored
    end
end
