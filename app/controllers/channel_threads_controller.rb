class ChannelThreadsController < ApplicationController
  include RoomScoped

  class ThreadUpdateForbidden < StandardError; end
  class InvalidThreadInvolvement < StandardError; end

  before_action :close_stale_threads
  before_action :set_thread, except: %i[ index create ]
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
    @messages = @thread.messages.with_creator.with_attachment_details.with_boosts.last_page
    no_store_response! if request.format.json?

    respond_to do |format|
      format.html
      format.json do
        render json: {
          thread: thread_payload(@thread),
          parent_message: message_payload(@thread.parent_message),
          messages: @messages.map { |message| message_payload(message, include_thread_summary: false) }
        }
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

  def create
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

  def update
    attributes = thread_update_attributes
    requested_status = attributes.delete(:status)

    ChannelThread.transaction do
      @thread.with_lock do
        @thread.reload
        ensure_current_parent_membership!
        raise ThreadUpdateForbidden unless allowed_thread_update?(attributes:, requested_status:)
        @thread.update!(attributes) if attributes.present?

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
      end
    end

    respond_to do |format|
      format.html { redirect_to room_thread_path(@room, @thread) }
      format.json { render json: { thread: thread_payload(@thread.reload) } }
    end
  rescue ActiveRecord::RecordInvalid => error
    render_error error.record.errors.full_messages.to_sentence
  rescue ThreadUpdateForbidden, ActiveRecord::RecordNotFound
    head :forbidden
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
    render json: { thread: thread_payload(@thread), membership: membership_payload(membership) }, status: :ok
  rescue InvalidThreadInvolvement
    render_error "Involvement must be one of nothing, mentions, or everything"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => error
    render_error error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : "Thread is inaccessible"
  end

  def leave
    @thread.memberships.find_by(user: Current.user)&.destroy!
    head :no_content
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

    def allowed_thread_update?(attributes:, requested_status:)
      return false if attributes.present? && !@thread.settings_manageable_by?(Current.user)

      case requested_status
      when nil
        true
      when "closed"
        @thread.settings_manageable_by?(Current.user)
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

    def thread_attributes
      permitted = params[:thread].present? ? params.require(:thread).permit(:name, :auto_archive_after_minutes) : params.permit(:name, :auto_archive_after_minutes)
      permitted.to_h.symbolize_keys.tap do |attributes|
        attributes[:auto_archive_after_minutes] = attributes[:auto_archive_after_minutes].to_i if attributes.key?(:auto_archive_after_minutes)
      end
    end

    def thread_update_attributes
      source = params[:thread].present? ? params.require(:thread) : params
      source.permit(:name, :auto_archive_after_minutes, :status).to_h.symbolize_keys.tap do |attributes|
        attributes[:auto_archive_after_minutes] = attributes[:auto_archive_after_minutes].to_i if attributes.key?(:auto_archive_after_minutes)
      end
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
      messages = @thread.messages.with_creator.with_attachment_details.with_boosts
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
