class MessagesController < ApplicationController
  include ActiveStorage::SetCurrent, RoomScoped

  before_action :set_room, except: :create
  before_action :set_message, only: %i[ show edit update destroy actions ]
  before_action :ensure_can_edit, only: %i[ edit update ]
  before_action :ensure_can_delete, only: :destroy

  layout false, only: :index

  def index
    no_store_response! if request.format.json?
    # The page is selected without its associations so that a conditional GET
    # can be answered from ids and timestamps alone. Only a request that is
    # actually going to render pays to load bodies, attachments and boosts.
    @messages = find_paged_messages

    if @messages.any?
      fresh_when @messages
      Message.preload_rendering_details(@messages) unless performed?
    else
      head :no_content
    end
  end

  def create
    set_room
    @message = @room.root_messages.new(message_params)
    apply_drive_file_ids!(@message) if drive_file_ids_key_present?
    @message.save!
    @message.process_attachment

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
    @message.assign_attributes(attributes)
    apply_drive_file_ids!(@message) if drive_file_ids_key_present?
    @message.save!

    @message.broadcast_replace_to @room, :messages, target: [ @message, :presentation ], partial: "messages/presentation", attributes: { maintain_scroll: true }
    if drive_file_ids_key_present?
      @message.broadcast_replace_to @room, :messages, target: [ @message, :drive_attachments ],
        partial: "messages/drive_attachments", locals: { message: @message }, attributes: { maintain_scroll: true }
    end

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
        paged_message_scope.page_before(@room.root_messages.find(params[:before]))
      when params[:after].present?
        paged_message_scope.page_after(@room.root_messages.find(params[:after]))
      else
        paged_message_scope.last_page
      end
    end

    # Subclasses that render something other than the message partials override
    # this to preload only what their representation reads.
    def paged_message_scope
      @room.root_messages
    end


    def message_params
      permitted = params.require(:message).permit(
        :body, :attachment, :client_message_id, :markdown_source,
        :reply_to_message_id, :reply_notify_author, drive_file_ids: []
      )
      permitted.delete(:drive_file_ids)

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

    # True when the form submitted the Drive attachment set at all. The edit
    # form always sends the key (with a blank sentinel so "remove all" is
    # expressible); the composer only sends it when the strip holds chips.
    # Absent means "leave the stored set alone".
    def drive_file_ids_key_present?
      params[:message].is_a?(ActionController::Parameters) && params[:message].key?(:drive_file_ids)
    end

    # nil when the key is not an array (a scalar would otherwise permit to an
    # empty set and silently remove everything).
    def normalized_drive_file_ids
      raw = params[:message][:drive_file_ids]
      return nil unless raw.is_a?(Array)

      raw.map { |id| id.to_s.strip }.reject(&:blank?).uniq
    end

    # Replaces the message's stored Drive set with the submitted ids, in
    # memory so the message and its attachments save in one transaction. An
    # invalid id raises before anything is written; the Drive scope is not
    # required because an id alone reveals nothing about the file.
    def apply_drive_file_ids!(message)
      ids = normalized_drive_file_ids

      if ids.nil? || ids.reject { |id| Google::DriveLink.valid_id?(id) }.any?
        message.errors.add :drive_attachments, "includes an invalid file id"
        raise ActiveRecord::RecordInvalid, message
      end

      current = message.drive_attachments.to_a
      current.each do |attachment|
        attachment.mark_for_destruction unless ids.include?(attachment.file_id)
      end
      (ids - current.map(&:file_id)).each do |file_id|
        message.drive_attachments.build(file_id:)
      end
    end

    def render_record_invalid(error)
      respond_to do |format|
        format.json { render json: { errors: error.record.errors.to_hash }, status: :unprocessable_content }
        format.any { head :unprocessable_content }
      end
    end


    def deliver_webhooks_to_bots
      # Agent-backed bots are delivered only through Agent::DeliveryJob (see
      # Message::AgentDelivery); the legacy webhook bypasses grant, rate, and
      # hop checks, so it serves bots without an Agent row only.
      bots_eligible_for_webhook.excluding(@message.creator).where.missing(:agent)
        .each { |bot| bot.deliver_webhook_later(@message) }
    end

    def bots_eligible_for_webhook
      @room.direct? ? @room.users.active_bots : @message.mentionees.active_bots
    end
end
