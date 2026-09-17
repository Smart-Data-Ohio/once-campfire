class Agents::EventsController < ApplicationController
  include AgentAuthorization

  allow_agent_access only: %i[ index ack ]

  before_action :ensure_agent_token, only: %i[ index ack ]
  before_action :set_ack_event, only: :ack
  require_agent_capability :read_messages, only: %i[ index ack ]

  LEDGER_PER_PAGE = 50
  POLL_DEFAULT_LIMIT = 50
  POLL_MAX_LIMIT = 100

  # GET /agents/events?since=<id>&limit=<n> (Bearer-only, JSON). Returns the
  # agent's own deliverable rows ordered by id. Readability (message exists,
  # membership, read grant) filters in SQL before the limit applies, so
  # revoked rows can never hide newer readable rows. Approval decision rows
  # carry no message and render an approval payload instead.
  def index
    no_store_response!

    agent = Current.agent
    since = params[:since].to_i
    limit = [ (params[:limit].presence || POLL_DEFAULT_LIMIT).to_i, 1 ].max
    limit = [ limit, POLL_MAX_LIMIT ].min

    events = agent.agent_events.readable_by(agent)
      .where("agent_events.id > ?", since)
      .where(outcome: %w[ pending delivered acknowledged ])
      .ordered
      .limit(limit)
      .includes(:room, :actor, message: [ :room, :rich_text_body, { creator: :avatar_attachment } ])
      .to_a

    @approval_cache = AgentApproval.where(id: events.filter_map { |event| event.metadata.is_a?(Hash) && event.metadata["approval_id"] }).index_by(&:id)

    render json: events.filter_map { |event| poll_payload(agent, event) }
  end

  # POST /agents/events/:id/ack (Bearer-only, JSON). Idempotent.
  def ack
    no_store_response!

    @agent_event.acknowledged! unless @agent_event.acknowledged?
    render json: { id: @agent_event.id, outcome: "acknowledged" }
  end

  # GET /agents/:id/events (HTML). Activity ledger for admins and the
  # agent's owner. Paginated, filterable by outcome. Bearer [REDACTED] are
  # denied by default; this is a session-authenticated management page.
  def ledger
    @agent = Agent.find(params[:id])
    @bot = @agent.user

    unless Current.user.administrator? || @agent.owner == Current.user
      head :forbidden
      return
    end

    @outcome_filter = params[:outcome].presence_in(AgentEvent::OUTCOMES)
    @page = [ params[:page].to_i, 1 ].max

    scope = @agent.agent_events.recent_first.includes(:room, :actor, :message)
    scope = scope.where(outcome: @outcome_filter) if @outcome_filter

    @events = scope.limit(LEDGER_PER_PAGE + 1).offset((@page - 1) * LEDGER_PER_PAGE).to_a
    @has_next = @events.size > LEDGER_PER_PAGE
    @events.pop if @has_next
  end

  private
    def ensure_agent_token
      unless authenticated_by.agent_token? && Current.agent
        render json: { error: "Forbidden: Bearer [REDACTED] token required" }, status: :forbidden
      end
    end

    def set_ack_event
      @agent_event = Current.agent.agent_events.deliverable
        .where.not(outcome: "suppressed")
        .find_by(id: params[:id])

      unless @agent_event
        head :not_found
        return
      end

      # Approval decisions carry no message and are always ackable by their
      # own agent. Clearing the room forces the capability check below to
      # the workspace-wide form, matching the polling endpoint.
      if @agent_event.event_type == "approval_decided"
        @room = nil
        @message = nil
        return
      end

      # Ack requires the row's message to be currently readable by the agent
      # under the same rule as polling: the message exists and the agent's
      # user is still a member of its room. A surviving workspace grant
      # alone is not enough.
      message = @agent_event.message
      unless message && Membership.exists?(user_id: Current.agent.user_id, room_id: message.room_id)
        head :not_found
        return
      end

      # Lets AgentAuthorization check the event's room.
      @room = @agent_event.room
      @message = message
    end

    def poll_payload(agent, event)
      if event.event_type == "approval_decided" || event.message_id.nil? && event.metadata.is_a?(Hash) && event.metadata["approval_id"]
        return approval_poll_payload(event)
      end

      message = event.message
      room = event.room
      return if message.nil? || room.nil?
      return unless Membership.exists?(user_id: agent.user_id, room_id: room.id)
      return unless agent.can?(:read_messages, room)

      {
        id: event.id,
        event_type: event.event_type,
        outcome: event.outcome,
        created_at: event.created_at&.utc,
        hop: event.hop,
        room: { id: room.id, name: room.name },
        actor: event.actor ? { id: event.actor.id, name: event.actor.name } : nil,
        message: message_payload(message)
      }.compact
    end

    def approval_poll_payload(event)
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      approval = @approval_cache&.dig(metadata["approval_id"]) || AgentApproval.find_by(id: metadata["approval_id"])
      return if approval.nil? || approval.agent_id != Current.agent.id

      room = event.room
      {
        id: event.id,
        event_type: event.event_type,
        outcome: event.outcome,
        created_at: event.created_at&.utc,
        room: room ? { id: room.id, name: room.name } : nil,
        actor: event.actor ? { id: event.actor.id, name: event.actor.name } : nil,
        approval: {
          id: approval.id,
          approval_id: approval.id,
          action: approval.action,
          summary: approval.summary,
          status: approval.effective_status,
          decided_by: approval.decided_by&.name || metadata["decided_by"],
          note: approval.decision_note || metadata["note"],
          expires_at: approval.expires_at&.utc,
          room_id: approval.room_id
        }.compact
      }.compact
    end
end
