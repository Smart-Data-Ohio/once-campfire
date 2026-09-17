class ChannelThreadsController < ApplicationController
  include RoomScoped

  class ThreadUpdateForbidden < StandardError; end
  class InvalidThreadInvolvement < StandardError; end

  before_action :close_stale_threads
  before_action :set_thread, except: %i[ index new create ]
  before_action :ensure_channel_room, only: :create
  before_action :ensure_thread_lifecycle_manager, only: :destroy

  def index
    @threads = thread_scope
    no_store_response! if request.format.json?

    respond_to do |format|
      format.html
      format.json { render json: { threads: @threads.map { |thread| thread_payload(thread) } } }
    end
  end

  def show
    set_show_details
    no_store_response! if request.format.json?

    respond_to do |format|
      format.html
      format.json do
        caching_thread_payloads do
          render json: {
            thread: thread_payload(@thread, include_work_history: true, include_work_owner_options: true),
            parent_message: message_payload(@thread.parent_message),
            messages: @messages.map { |message| message_payload(message, include_thread_summary: false) }
          }
        end
      end
    end
  end

  def content
    no_store_response!
    @messages, @content_anchor = find_content_messages
    response.headers["X-Thread-Content-At-Latest"] = (@content_anchor.nil?).to_s
    render partial: "channel_threads/conversation", locals: {
      room: @room,
      thread: @thread,
      messages: @messages,
      anchor_message_id: @content_anchor&.id
    }, layout: false
  end

  # The new-post form exists only in boards; channel threads start from the
  # thread panel instead.
  def new
    return head :not_found unless @room.board?

    @thread = @room.channel_threads.new(work_status: "planned")
  end

  def create
    if @room.board?
      create_board_post
    else
      create_channel_thread
    end
  end

  def update
    attributes = thread_update_attributes
    requested_status = attributes.delete(:status)
    work_attributes = thread_work_update_attributes(attributes)
    tags_submitted = attributes.key?(:tags)
    tag_names = attributes.delete(:tags)
    result_submitted = attributes.key?(:result_markdown)
    result_markdown = attributes.delete(:result_markdown)

    ChannelThread.transaction do
      @thread.with_lock do
        @thread.reload
        ensure_current_parent_membership!
        reject_board_auto_archive_change!(attributes)
        unless allowed_thread_update?(attributes:, requested_status:, work_attributes:,
            tags_submitted:, result_submitted:)
          raise ThreadUpdateForbidden
        end
        @thread.tag_names = tag_names if tags_submitted
        @thread.update!(attributes) if attributes.present? || tags_submitted

        case requested_status
        when "active"
          if @thread.locked?
            @thread.update!(locked_at: nil, closed_at: nil)
          elsif @thread.closed?
            @thread.update!(closed_at: nil)
          end
        when "closed"
          @thread.update!(closed_at: Time.current) unless @thread.locked? || @thread.closed?
        when "locked"
          now = Time.current
          @thread.update!(closed_at: @thread.closed_at || now, locked_at: @thread.locked_at || now)
        when nil
          # A name or archive-setting update does not change lifecycle state.
        else
          raise ActiveRecord::RecordInvalid.new(@thread.tap { |thread| thread.errors.add(:status, "is invalid") })
        end

        @thread.update_result!(actor: Current.user, markdown: result_markdown) if result_submitted
        @thread.update_work!(actor: Current.user, **work_attributes) if work_attributes.present?
      end
    end

    respond_to do |format|
      format.html { redirect_to room_thread_path(@room, @thread) }
      format.json { render json: { thread: thread_payload(@thread.reload, include_work_history: true, include_work_owner_options: true) } }
    end
  rescue ActiveRecord::RecordInvalid => error
    if request.format.html?
      @post_error = error.record.errors.full_messages.to_sentence
      set_show_details
      render :show, status: :unprocessable_entity
    else
      render_error error.record.errors.full_messages.to_sentence
    end
  rescue ThreadUpdateForbidden, ChannelThread::WorkUpdateForbidden, ActiveRecord::RecordNotFound
    if request.format.html?
      redirect_to room_thread_path(@room, @thread), alert: "You are not allowed to change this post."
    else
      head :forbidden
    end
  end

  def destroy
    @thread.destroy!
    respond_to do |format|
      format.html { redirect_to room_path(@room) }
      format.any { head :no_content }
    end
  end

  def join
    no_store_response!
    involvement = requested_thread_involvement
    membership = ThreadMembership.join!(@thread, Current.user)
    membership.update!(involvement:) if involvement

    respond_to do |format|
      format.html { redirect_to room_thread_path(@room, @thread) }
      format.json { render json: { thread: thread_payload(@thread), membership: membership_payload(membership) }, status: :ok }
    end
  rescue InvalidThreadInvolvement
    render_error "Involvement must be one of nothing, mentions, or everything"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => error
    render_error error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : "Thread is inaccessible"
  end

  def leave
    @thread.memberships.find_by(user: Current.user)&.destroy!

    respond_to do |format|
      format.html { redirect_to room_thread_path(@room, @thread) }
      format.any { head :no_content }
    end
  end

  def read
    no_store_response!
    membership = @thread.memberships.find_by!(user: Current.user)
    membership.read
    render json: { thread: thread_payload(@thread), membership: membership_payload(membership) }
  rescue ActiveRecord::RecordNotFound
    render_error "Join the thread before marking it read", status: :not_found
  end

  private
    def close_stale_threads
      ChannelThread.close_stale_in(room: @room)
    end

    def set_thread
      @thread = @room.channel_threads.find(params[:id])
    end

    def thread_scope
      scope = @room.channel_threads.ordered
      case params[:state].to_s
      when "active", "open", ""
        scope.active
      when "work", "working"
        scope.work.where.not(work_status: "done")
      when "done", "completed"
        scope.work.where(work_status: "done")
      when "closed"
        scope.closed
      when "locked"
        scope.locked
      when "all"
        scope
      else
        scope.active
      end
    end

    def ensure_channel_room
      render_error "Direct rooms cannot contain channel threads", status: :forbidden if @room.direct?
    end

    def ensure_thread_lifecycle_manager
      head :forbidden unless @thread.lifecycle_manageable_by?(Current.user)
    end

    def create_channel_thread
      parent_message = parent_message_from_params

      ChannelThread.transaction do
        @thread = @room.channel_threads.create!(thread_attributes.merge(creator: Current.user, parent_message: parent_message))
        ThreadMembership.join!(@thread, Current.user)

        if initial_message_attributes.present?
          create_thread_message!(initial_message_attributes)
        end
      end

      respond_to do |format|
        format.html { redirect_to room_thread_path(@room, @thread) }
        format.json { render json: { thread: thread_payload(@thread.reload), parent_message: message_payload(@thread.parent_message) }, status: :created }
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue ActiveRecord::RecordNotUnique
      render_error "A thread already exists for that message", status: :conflict
    rescue ActiveRecord::RecordInvalid => error
      render_error error.record.errors.full_messages.to_sentence
    end

    # A board post is tracked work from creation. An assigned agent goes
    # through the existing work assignment so its ledger records the
    # work_assigned event; a first message notifies the board.
    def create_board_post
      board_attributes = board_post_attributes
      owner_id = board_attributes[:work_owner_id].presence
      first_message = board_first_message

      ChannelThread.transaction do
        @thread = @room.channel_threads.new(
          name: board_attributes[:name],
          work_status: board_attributes[:work_status].presence || "planned",
          creator: Current.user
        )
        @thread.tag_names = board_attributes[:tags] if board_attributes.key?(:tags)
        @thread.save!
        ThreadMembership.join!(@thread, Current.user)

        message = if first_message.present?
          @thread.post_message!(creator: Current.user, attributes: first_message)
        end
        @thread.update_work!(actor: Current.user, work_owner_id: owner_id) if owner_id
        notify_board_post_created!(@thread, message) if message
      end

      respond_to do |format|
        format.html { redirect_to room_thread_path(@room, @thread) }
        format.json { render json: { thread: thread_payload(@thread.reload), parent_message: message_payload(@thread.parent_message) }, status: :created }
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue ActiveRecord::RecordInvalid => error
      @thread ||= @room.channel_threads.new(board_post_attributes.except(:tags).merge(creator: Current.user))
      @thread.tag_names = board_post_attributes[:tags] if board_post_attributes.key?(:tags) && @thread.tag_names.blank?

      respond_to do |format|
        format.html do
          @post_error = error.record.errors.full_messages.to_sentence
          render :new, status: :unprocessable_entity
        end
        format.any { render_error error.record.errors.full_messages.to_sentence }
      end
    end

    # A new post notifies board members following everything, plus the
    # assigned human owner whatever their involvement, sourced at the
    # opening message so the inbox can open its exact context.
    def notify_board_post_created!(thread, message)
      memberships = thread.room.memberships.includes(:user).to_a

      memberships.each do |membership|
        user = membership.user
        next unless user&.active? && !user.bot?
        next if user.id == thread.creator_id
        next if membership.involved_in_invisible?
        next unless membership.involved_in_everything? || user.id == thread.work_owner_id

        ActivityItem.create!(user:, source: message, event_type: "thread_activity")
      end
    end

    # Posts never auto-archive; the control is hidden and the server rejects
    # the change outright.
    def reject_board_auto_archive_change!(attributes)
      return unless @room.board? && attributes.key?(:auto_archive_after_minutes)

      @thread.errors.add(:auto_archive_after_minutes, "is not available for board posts")
      raise ActiveRecord::RecordInvalid.new(@thread)
    end

    def allowed_thread_update?(attributes:, requested_status:, work_attributes:, tags_submitted: false, result_submitted: false)
      if attributes.present? || tags_submitted
        return false unless thread_metadata_manageable?
      end

      if result_submitted
        return false unless @thread.work_status_manageable_by?(Current.user)
      end

      if work_attributes.present?
        return false unless @thread.work_manageable_by?(Current.user)
        return false if work_attributes.key?(:work_owner_id) && !@thread.work_assignment_manageable_by?(Current.user)

        if work_attributes.key?(:work_status)
          requested_work_status = work_attributes[:work_status].to_s.presence
          conversion = @thread.work_status.present? != requested_work_status.present?
          return false if conversion && !@thread.work_conversion_manageable_by?(Current.user)
        end
      end

      case requested_status
      when nil
        true
      when "closed"
        @room.board? ? @thread.lifecycle_manageable_by?(Current.user) : @thread.settings_manageable_by?(Current.user)
      when "locked"
        @thread.lifecycle_manageable_by?(Current.user)
      when "active"
        if @thread.locked?
          @thread.lifecycle_manageable_by?(Current.user)
        elsif @thread.closed?
          @thread.memberships.exists?(user_id: Current.user.id)
        else
          true
        end
      else
        false
      end
    end

    def ensure_current_parent_membership!
      Membership.lock.find_by!(room: @room, user: Current.user)
    end

    # Title and tag edits follow the rename rule in channels but the status
    # rule in boards, where the post owner manages them too.
    def thread_metadata_manageable?
      @room.board? ? @thread.work_manageable_by?(Current.user) : @thread.settings_manageable_by?(Current.user)
    end

    def set_show_details
      @messages = @thread.messages.with_rendering_details.last_page
      if @thread.work? && request.format.html?
        @work_links = @thread.work_thread_links.ordered.includes(:github_pull_request, :event).to_a
        @linkable_events = @room.events.upcoming.soonest_first
          .where.not(id: @thread.work_thread_links.where.not(event_id: nil).select(:event_id))
          .to_a
      end
    end

    def thread_attributes
      permitted = params[:thread].present? ? params.require(:thread).permit(:name, :auto_archive_after_minutes) : params.permit(:name, :auto_archive_after_minutes)
      permitted.to_h.symbolize_keys.tap do |attributes|
        attributes[:auto_archive_after_minutes] = attributes[:auto_archive_after_minutes].to_i if attributes.key?(:auto_archive_after_minutes)
      end
    end

    def thread_update_attributes
      source = params[:thread].present? ? params.require(:thread) : params
      source.permit(:name, :auto_archive_after_minutes, :status, :work_status, :work_owner_id, :tags, :result_markdown).to_h.symbolize_keys.tap do |attributes|
        attributes[:auto_archive_after_minutes] = attributes[:auto_archive_after_minutes].to_i if attributes.key?(:auto_archive_after_minutes)
      end
    end

    def board_post_attributes
      source = params[:thread].present? ? params.require(:thread) : params
      source.permit(:name, :work_status, :work_owner_id, :tags).to_h.symbolize_keys
    end

    def board_first_message
      source = params[:thread].present? ? params.require(:thread) : params
      markdown_source = source.permit(:first_message).fetch(:first_message, "").to_s
      return {} if markdown_source.blank?

      { markdown_source: markdown_source }
    end

    def thread_work_update_attributes(attributes)
      work_attributes = {}
      if attributes.key?(:work_status)
        work_attributes[:work_status] = attributes.delete(:work_status)
      end

      if attributes.key?(:work_owner_id)
        work_attributes[:work_owner_id] = attributes.delete(:work_owner_id)
      end

      work_attributes[:work_owner_id] = nil if work_attributes[:work_owner_id].respond_to?(:empty?) && work_attributes[:work_owner_id].empty?
      work_attributes
    end

    def parent_message_from_params
      parent_id = if params[:thread].present?
        params[:thread][:parent_message_id]
      else
        params[:parent_message_id]
      end
      return if parent_id.blank?

      @room.root_messages.find(parent_id)
    end

    def initial_message_attributes
      source = params[:message] || params[:thread]&.[](:message)
      return {} if source.blank?

      parameters = source.is_a?(ActionController::Parameters) ? source : ActionController::Parameters.new(source)
      permitted = parameters.permit(
        :body, :attachment, :markdown_source, :client_message_id, :reply_to_message_id, :reply_notify_author, :forward_note
      )
      if permitted.key?(:markdown_source) && !permitted[:markdown_source].nil?
        permitted.delete(:body)
      end
      permitted.to_h.symbolize_keys
    end

    def create_thread_message!(attributes)
      attributes[:reply_to_message_id] = attributes[:reply_to_message_id].presence
      attributes[:reply_notify_author] = ActiveModel::Type::Boolean.new.cast(attributes[:reply_notify_author]) if attributes.key?(:reply_notify_author)
      @thread.post_message!(creator: Current.user, attributes: attributes)
    end

    def find_content_messages
      messages = @thread.messages.with_rendering_details
      return [ messages.last_page, nil ] if params[:message_id].blank?

      anchor = @thread.messages.find(params[:message_id])
      [ messages.page_around(anchor), anchor ]
    end

    def membership_payload(membership)
      {
        id: membership.id,
        user_id: membership.user_id,
        involvement: membership.involvement,
        unread_at: membership.unread_at&.utc,
        joined_at: membership.joined_at&.utc
      }
    end

    # Joining is also the one place the client may set a thread-specific
    # notification preference.  Validate before creating a membership so an
    # invalid request cannot turn a browse into an implicit join.
    def requested_thread_involvement
      return unless params.key?(:involvement)

      involvement = params[:involvement].to_s
      return involvement if ThreadMembership.involvements.key?(involvement)

      raise InvalidThreadInvolvement
    end

    def render_error(message, status: :unprocessable_content)
      respond_to do |format|
        format.html { head status }
        format.json { render json: { error: message }, status: status }
        format.any { head status }
      end
    end
end
