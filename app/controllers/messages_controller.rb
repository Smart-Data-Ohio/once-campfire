class MessagesController < ApplicationController
  include ActiveStorage::SetCurrent, RoomScoped

  before_action :set_room, except: :create
  before_action :set_message, only: %i[ show edit update destroy ]
  before_action :ensure_can_administer, only: %i[ edit update destroy ]

  layout false, only: :index

  def index
    @messages = find_paged_messages

    if @messages.any?
      fresh_when @messages
    else
      head :no_content
    end
  end

  def create
    set_room
    @message = @room.messages.create_with_attachment!(message_params)

    @message.broadcast_create
    deliver_webhooks_to_bots
  rescue ActiveRecord::RecordNotFound
    render action: :room_not_found
  rescue ActiveRecord::RecordInvalid => error
    render_record_invalid(error)
  end

  def show
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

  def edit
  end

  def update
    @message.update!(message_params)

    @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation", attributes: { maintain_scroll: true }

    respond_to do |format|
      format.html { redirect_to room_message_url(@room, @message) }
      format.json { render :show }
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
      @message = @room.messages.find(params[:id])
    end

    def ensure_can_administer
      head :forbidden unless Current.user.can_administer?(@message)
    end


    def find_paged_messages
      case
      when params[:before].present?
        @room.messages.with_creator.page_before(@room.messages.find(params[:before]))
      when params[:after].present?
        @room.messages.with_creator.page_after(@room.messages.find(params[:after]))
      else
        @room.messages.with_creator.last_page
      end
    end


    def message_params
      permitted = params.require(:message).permit(:body, :attachment, :client_message_id, :markdown_source)

      if permitted.key?(:markdown_source) && !permitted[:markdown_source].nil?
        permitted.delete(:body)
      elsif action_name == "update"
        permitted[:markdown_source] = nil
      end

      permitted
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
