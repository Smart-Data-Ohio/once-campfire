class MessagesController < ApplicationController
  include ActiveStorage::SetCurrent, RoomScoped

  before_action :set_room, except: :create
  before_action :set_message, only: %i[ show edit update destroy actions ]
  before_action :ensure_can_edit, only: %i[ edit update ]
  before_action :ensure_can_delete, only: :destroy

  layout false, only: :index

  def index
    no_store_response! if request.format.json?
    @messages = find_paged_messages

    if @messages.any?
      fresh_when @messages
    else
      head :no_content
    end
  end

  def create
    set_room
    @message = @room.root_messages.create_with_attachment!(message_params)

    @message.broadcast_create
    deliver_webhooks_to_bots
  rescue ActiveRecord::RecordNotFound
    render action: :room_not_found
  rescue ActiveRecord::RecordInvalid => error
    render_record_invalid(error)
  end

  def show
    no_store_response! if request.format.json?
  end

  def preview
    source = params.require(:message).permit(:markdown_source).fetch(:markdown_source)

    if source.length > Message::Markdown::SOURCE_LIMIT
      render json: { error: "Markdown is limited to #{Message::Markdown::SOURCE_LIMIT.to_fs(:delimited)} characters" }, status: :unprocessable_content
    else
      content = ActionText::Content.new(Message::Markdown.render(source, room: @room))
      render json: { html: view_context.markdown_message_presentation(content) }
    end
  end

  def actions
    no_store_response!
    render json: { actions: message_actions_payload(@message) }
  end

  def edit
  end

  def update
    attributes = message_params
    @message.preserve_legacy_attachments_on_next_markdown_render! if !@message.markdown? && attributes[:markdown_source].present?
    @message.update!(attributes)

    @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation", attributes: { maintain_scroll: true }

    respond_to do |format|
      format.html { redirect_to room_message_url(@room, @message) }
      format.json { render json: message_payload(@message) }
    end
  rescue ActiveRecord::RecordInvalid => error
    render_record_invalid(error)
  end

  def destroy
    @message.destroy
    @message.broadcast_remove
  end

  private
    def set_message
      @message = @room.root_messages.find(params[:id])
    end

    def ensure_can_edit
      head :forbidden unless Current.user == @message.creator
    end

    def ensure_can_delete
      head :forbidden unless Current.user == @message.creator || Current.user.administrator?
    end


    def find_paged_messages
      case
      when params[:before].present?
        @room.root_messages.with_creator.page_before(@room.root_messages.find(params[:before]))
      when params[:after].present?
        @room.root_messages.with_creator.page_after(@room.root_messages.find(params[:after]))
      else
        @room.root_messages.with_creator.last_page
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

      if permitted.key?(:reply_to_message_id)
        permitted[:reply_to_message_id] = if permitted[:reply_to_message_id].present?
          @room.root_messages.find(permitted[:reply_to_message_id]).id
        end
      end
      if permitted.key?(:reply_notify_author)
        permitted[:reply_notify_author] = ActiveModel::Type::Boolean.new.cast(permitted[:reply_notify_author])
      end

      permitted.to_h.symbolize_keys
    end

    def render_record_invalid(error)
      respond_to do |format|
        format.json { render json: { errors: error.record.errors.to_hash }, status: :unprocessable_content }
        format.any { head :unprocessable_content }
      end
    end


    def deliver_webhooks_to_bots
      bots_eligible_for_webhook.excluding(@message.creator).each { |bot| bot.deliver_webhook_later(@message) }
    end

    def bots_eligible_for_webhook
      @room.direct? ? @room.users.active_bots : @message.mentionees.active_bots
    end
end
