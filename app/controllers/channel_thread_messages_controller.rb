class ChannelThreadMessagesController < ApplicationController
  include RoomScoped

  before_action :close_stale_threads
  before_action :set_thread
  before_action :set_message, only: %i[ show update destroy actions ]
  before_action :ensure_can_edit, only: :update
  before_action :ensure_can_delete, only: :destroy
  before_action :ensure_thread_message_writable, only: :update

  def index
    @messages = find_paged_messages
    no_store_response! if request.format.json?

    respond_to do |format|
      format.html
      format.json { render json: { messages: @messages.map { |message| message_payload(message, include_thread_summary: false) } } }
    end
  end

  def show
    no_store_response! if request.format.json?
    respond_to do |format|
      # A thread message belongs in the parent room shell, where the selected
      # thread has its composer and context panel. Keep this nested URL for
      # JSON/REST operations, but make a human navigation land in that shell.
      format.html { redirect_to room_path(@room, thread: @thread.id, message_id: @message.id) }
      format.json { render json: message_payload(@message, include_thread_summary: false) }
    end
  end

  def actions
    no_store_response!
    render json: { actions: message_actions_payload(@message) }
  end

  def create
    @message = @thread.post_message!(creator: Current.user, attributes: message_params)

    @message.broadcast_create
    no_store_response! if request.format.json?
    respond_to do |format|
      format.html { redirect_to room_thread_path(@room, @thread) }
      format.json { render json: message_payload(@message, include_thread_summary: false), status: :created }
      format.turbo_stream
    end
  rescue ActiveRecord::RecordInvalid => error
    render_error error.record.errors.full_messages.to_sentence
  rescue ChannelThread::LockedError => error
    render_error error.message, status: :forbidden
  end

  def update
    attributes = message_params
    @thread.with_lock do
      @thread.reload
      raise ChannelThread::LockedError, "This thread is locked" if @thread.locked?

      @message.reload
      @message.preserve_legacy_attachments_on_next_markdown_render! if !@message.markdown? && attributes[:markdown_source].present?
      @message.update!(attributes)
    end
    @message.broadcast_replace_to @thread, :messages,
      target: [ @message, :presentation ], partial: "messages/presentation", attributes: { maintain_scroll: true }

    no_store_response! if request.format.json?
    respond_to do |format|
      format.html { redirect_to room_thread_message_path(@room, @thread, @message) }
      format.json { render json: message_payload(@message, include_thread_summary: false) }
    end
  rescue ActiveRecord::RecordInvalid => error
    render_error error.record.errors.full_messages.to_sentence
  rescue ChannelThread::LockedError => error
    render_error error.message, status: :forbidden
  end

  def destroy
    @message.destroy!
    @message.broadcast_remove

    respond_to do |format|
      format.html { redirect_to room_thread_path(@room, @thread) }
      format.any { head :no_content }
    end
  end

  private
    def close_stale_threads
      ChannelThread.close_stale_in(room: @room)
    end

    def set_thread
      @thread = @room.channel_threads.find(params[:thread_id])
    end

    def set_message
      @message = @thread.messages.find(params[:id])
    end

    def ensure_can_edit
      head :forbidden unless Current.user == @message.creator
    end

    def ensure_can_delete
      head :forbidden unless Current.user == @message.creator || Current.user.administrator?
    end

    def ensure_thread_message_writable
      return unless @thread.locked?

      head :forbidden
    end

    def find_paged_messages
      messages = @thread.messages.with_creator.with_attachment_details.with_boosts
      case
      when params[:before].present?
        messages.page_before(@thread.messages.find(params[:before]))
      when params[:after].present?
        messages.page_after(@thread.messages.find(params[:after]))
      else
        messages.last_page
      end
    end

    def message_params
      permitted = params.require(:message).permit(
        :body, :attachment, :client_message_id, :markdown_source,
        :reply_to_message_id, :reply_notify_author
      )

      if permitted.key?(:markdown_source) && !permitted[:markdown_source].nil?
        permitted.delete(:body)
      elsif action_name == "update"
        permitted[:markdown_source] = nil
      end

      permitted[:reply_to_message_id] = permitted[:reply_to_message_id].presence if permitted.key?(:reply_to_message_id)
      if permitted.key?(:reply_notify_author)
        permitted[:reply_notify_author] = ActiveModel::Type::Boolean.new.cast(permitted[:reply_notify_author])
      end
      permitted.to_h.symbolize_keys
    end

    def render_error(message, status: :unprocessable_content)
      respond_to do |format|
        format.html { head status }
        format.json { render json: { error: message }, status: status }
        format.any { head status }
      end
    end
end
