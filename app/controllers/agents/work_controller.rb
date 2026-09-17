class Agents::WorkController < ApplicationController
  allow_agent_access only: %i[ index show update result ]

  before_action :ensure_agent_token, only: %i[ index show update result ]
  before_action :set_owned_thread, only: %i[ show update result ]

  LIST_MAX_LIMIT = 100

  # GET /agents/work (Bearer-only, JSON). Lists the threads the agent
  # currently owns, newest first, max 100, filtered to rooms the agent's
  # user still belongs to and where the agent holds read_messages.
  def index
    no_store_response!

    agent = Current.agent
    threads = ChannelThread.work.where(work_owner_id: agent.user_id)
      .where(room_id: Membership.where(user_id: agent.user_id).select(:room_id))
      .includes(:room, :work_owner, :tags, work_thread_links: %i[ github_pull_request event ]).order(updated_at: :desc, id: :desc).to_a
    threads.select! { |thread| agent.can?(:read_messages, thread.room) }

    render json: threads.first(LIST_MAX_LIMIT).map { |thread| work_thread_payload(thread) }
  end

  # GET /agents/work/:id (Bearer-only, JSON). Returns one owned thread.
  # Anything the agent does not own is 404.
  def show
    no_store_response!

    render json: work_thread_payload(@thread)
  end

  # PATCH /agents/work/:id (Bearer-only, JSON). Updates the status, tags,
  # and run_url of a thread the agent owns, with an optional plain-text
  # note (max 500) recorded in the WorkThreadEvent. Each field updates
  # only when its key is given; tags takes an array or a comma-separated
  # string and run_url must be https, with blank clearing either. Anything
  # the agent does not own is 404; a missing manage_threads grant in the
  # thread's room is 403. Agents cannot reassign, convert, or stop tracking.
  def update
    no_store_response!

    unless Current.agent.can?(:manage_threads, @thread.room)
      render json: { error: "Forbidden: agent lacks manage_threads capability" }, status: :forbidden
      return
    end

    begin
      @thread.update_work_by_agent!(
        agent: Current.agent,
        work_status: agent_work_field(:work_status),
        note: params[:note].presence || params.dig(:work, :note),
        tags: agent_work_field(:tags),
        run_url: agent_work_field(:run_url)
      )
    rescue ActiveRecord::RecordInvalid => error
      render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      return
    end

    render json: work_thread_payload(@thread.reload)
  end

  # PUT /agents/work/:id/result (Bearer-only, JSON). Replaces the pinned
  # result of a thread the agent owns: markdown is required (max 20,000
  # characters), blank clears, an unchanged value writes nothing, and
  # every write records a result_updated event. Anything the agent does
  # not own is 404; a missing manage_threads grant in the thread's room
  # is 403.
  def result
    no_store_response!

    unless Current.agent.can?(:manage_threads, @thread.room)
      render json: { error: "Forbidden: agent lacks manage_threads capability" }, status: :forbidden
      return
    end

    unless params.key?(:markdown)
      render json: { error: "Markdown can't be blank" }, status: :unprocessable_entity
      return
    end

    begin
      @thread.update_result_by_agent!(agent: Current.agent, markdown: params[:markdown])
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
        .includes(:room, :work_owner, :tags, work_thread_links: %i[ github_pull_request event ]).find_by(id: params[:id])
      head :not_found unless @thread && @thread.room.memberships.exists?(user_id: Current.agent.user_id)
    end

    def work_thread_payload(thread)
      Agents::WorkPayload.for(thread)
    end

    # Reads an updatable work field from the top level or the nested work
    # object, the top level winning when both carry the key. Returns the
    # unset sentinel when neither does, so the model can tell an omitted
    # field from an explicit blank.
    def agent_work_field(key)
      return params[key] if params.key?(key)

      nested = params[:work]
      return ChannelThread::UNSET_WORK_VALUE unless nested.respond_to?(:key?) && nested.key?(key)

      nested[key]
    end
end
