class Agents::PostsController < ApplicationController
  include AgentAuthorization

  allow_agent_access only: %i[ index create ]

  # Bearer-only endpoint. Forgery protection stays on: Bearer agent already
  # bypass it through the Authentication concern, and a session-cookie request
  # that trips it gets the same 403 JSON that ensure_agent_token would return.
  rescue_from ActionController::InvalidAuthenticityToken, with: :reject_session_request

  before_action :set_room, only: %i[ index create ]
  before_action :ensure_agent_token, only: %i[ index create ]
  before_action :ensure_board_room, only: %i[ index create ]
  require_agent_capability :read_messages, only: :index
  require_agent_capability :post_messages, only: :create
  require_agent_capability :manage_threads, only: :create

  LIST_MAX_LIMIT = 100
  LIST_STATUSES = %w[ planned in_progress blocked done open all ].freeze
  LIST_OWNER_FILTERS = %w[ me agents ].freeze

  # GET /rooms/:room_id/agents/posts (Bearer-only, JSON). The board's
  # posts as work payloads, newest activity first, max 100. status is a
  # single work status or open/done/all (default open); owner is a user
  # id, me, or agents; tag is a single tag.
  def index
    no_store_response!

    status_filter = params[:status].to_s.strip.presence || "open"
    unless LIST_STATUSES.include?(status_filter)
      render json: { error: "Status must be one of #{LIST_STATUSES.join(", ")}" }, status: :unprocessable_entity
      return
    end

    owner_filter = params[:owner].to_s.strip
    unless owner_filter.blank? || LIST_OWNER_FILTERS.include?(owner_filter) || owner_filter.match?(/\A\d+\z/)
      render json: { error: "Owner must be a user id, me, or agents" }, status: :unprocessable_entity
      return
    end

    scope = @room.channel_threads.ordered
      .includes(:room, :work_owner, :tags, work_thread_links: %i[ github_pull_request event ])

    scope = case status_filter
    when "done"
      scope.work.where(work_status: "done")
    when "all"
      scope
    when "open"
      scope.work.where.not(work_status: "done")
    else
      scope.work.where(work_status: status_filter)
    end

    scope = case owner_filter
    when "me"
      scope.where(work_owner_id: Current.agent.user_id)
    when "agents"
      scope.where(work_owner_id: Agent.select(:user_id))
    when /\A\d+\z/
      scope.where(work_owner_id: owner_filter.to_i)
    else
      scope
    end

    tag_filter = params[:tag].to_s.strip.downcase
    if tag_filter.present?
      scope = scope.where(id: ThreadTag.where(name: tag_filter).select(:channel_thread_id))
    end

    render json: scope.limit(LIST_MAX_LIMIT).map { |thread| Agents::WorkPayload.for(thread) }
  end

  # POST /rooms/:room_id/agents/posts (Bearer-only, JSON). Creates a post
  # through the same path as the human new-post form: title (required),
  # body (Markdown for the first message, optional), tags (array or
  # comma-separated string), work_status (default in_progress), run_url
  # (https only), and owner_id (an eligible member or agent, defaulting
  # to the agent itself). Requires post_messages and manage_threads in
  # the board. Returns the work payload.
  def create
    no_store_response!

    agent = Current.agent
    thread = ChannelThread.create_board_post!(
      room: @room,
      creator: agent.user,
      name: params[:title],
      work_status: params[:work_status].presence || "in_progress",
      owner_id: params[:owner_id].presence || agent.user_id,
      tags: params[:tags],
      run_url: params[:run_url],
      first_message: params[:body]
    )

    render json: Agents::WorkPayload.for(thread), status: :created
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordInvalid => error
    render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  private
    def set_room
      @room = Current.user.rooms.find_by(id: params[:room_id])

      head :not_found unless @room
    end

    def ensure_agent_token
      reject_session_request unless authenticated_by.agent_token?
    end

    def ensure_board_room
      return if @room.board?

      render json: { error: "Room is not a board" }, status: :unprocessable_entity
    end

    def reject_session_request
      render json: { error: "Forbidden: Bearer agent token required" }, status: :forbidden
    end
end
