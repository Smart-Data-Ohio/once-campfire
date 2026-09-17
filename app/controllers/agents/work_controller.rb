class Agents::WorkController < ApplicationController
  allow_agent_access only: %i[ index show update ]

  before_action :ensure_agent_token, only: %i[ index show update ]
  before_action :set_owned_thread, only: %i[ show update ]

  LIST_MAX_LIMIT = 100

  # GET /agents/work (Bearer-only, JSON). Lists the threads the agent
  # currently owns, newest first, max 100, filtered to rooms the agent's
  # user still belongs to and where the agent holds read_messages.
  def index
    no_store_response!

    agent = Current.agent
    threads = ChannelThread.work.where(work_owner_id: agent.user_id)
      .where(room_id: Membership.where(user_id: agent.user_id).select(:room_id))
      .includes(:room, work_thread_links: %i[ github_pull_request event ]).order(updated_at: :desc, id: :desc).to_a
    threads.select! { |thread| agent.can?(:read_messages, thread.room) }

    render json: threads.first(LIST_MAX_LIMIT).map { |thread| work_thread_payload(thread) }
  end

  # GET /agents/work/:id (Bearer-only, JSON). Returns one owned thread.
  # Anything the agent does not own is 404.
  def show
    no_store_response!

    render json: work_thread_payload(@thread)
  end

  # PATCH /agents/work/:id (Bearer-only, JSON). Updates the status of a
  # thread the agent owns, with an optional plain-text note (max 500)
  # recorded in the WorkThreadEvent. Anything the agent does not own is
  # 404; a missing manage_threads grant in the thread's room is 403.
  # Agents cannot reassign, convert, or stop tracking.
  def update
    no_store_response!

    unless Current.agent.can?(:manage_threads, @thread.room)
      render json: { error: "Forbidden: agent lacks manage_threads capability" }, status: :forbidden
      return
    end

    begin
      @thread.update_work_status_by_agent!(
        agent: Current.agent,
        work_status: params[:work_status].presence || params.dig(:work, :work_status),
        note: params[:note].presence || params.dig(:work, :note)
      )
    rescue ActiveRecord::RecordInvalid => error
      render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      return
    end

    render json: work_thread_payload(@thread.reload)
  end

  private
    def ensure_agent_token
      unless authenticated_by.agent_token? && Current.agent
        render json: { error: "Forbidden: Bearer agent token required" }, status: :forbidden
      end
    end

    # Ownership plus current room membership: like every other agent
    # endpoint, a room the agent's user no longer belongs to answers 404.
    def set_owned_thread
      @thread = ChannelThread.work.where(work_owner_id: Current.agent.user_id)
        .includes(:room, work_thread_links: %i[ github_pull_request event ]).find_by(id: params[:id])
      head :not_found unless @thread && @thread.room.memberships.exists?(user_id: Current.agent.user_id)
    end

    def work_thread_payload(thread)
      {
        id: thread.id,
        room_id: thread.room_id,
        title: thread.name,
        work_status: thread.work_status,
        url: room_path(thread.room, thread: thread.id),
        updated_at: thread.updated_at&.utc,
        links: WorkThreadLink.agent_payloads_for(thread)
      }
    end
end
