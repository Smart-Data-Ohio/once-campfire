class MessageForwardsController < ApplicationController
  before_action :set_source

  def create
    @results = Messages::Forwarder.call(
      source: @source,
      destinations: forward_destinations,
      note: forward_note,
      creator: Current.user
    )
    @results.each { |result| result.message.broadcast_create }

    no_store_response!
    respond_to do |format|
      format.html { redirect_to message_permalink_url(@source) }
      format.json do
        render json: {
          forwards: @results.map do |result|
            {
              destination: { room_id: result.room.id, thread_id: result.thread&.id },
              message: message_payload(result.message)
            }
          end
        }, status: :created
      end
    end
  rescue Messages::Forwarder::TooManyDestinations, Messages::Forwarder::InvalidDestination => error
    render_error error.message, status: :unprocessable_content
  rescue ActiveRecord::RecordInvalid => error
    render_error error.record.errors.full_messages.to_sentence
  end

  # The picker is server-authoritative: it exposes only rooms the current user
  # can reach and only unlocked threads in those rooms. The browser must not
  # infer destinations from whatever happens to be visible in its sidebar.
  def destinations
    no_store_response!
    Current.user.rooms.find_each { |room| ChannelThread.close_stale_in(room:) unless room.direct? }

    render json: {
      destinations: Current.user.rooms.ordered.map do |room|
        {
          room_id: room.id,
          name: view_context.room_display_name(room),
          direct: room.direct?,
          threads: room.direct? ? [] : room.channel_threads.where(locked_at: nil).ordered.map do |thread|
            { id: thread.id, name: thread.name, status: thread.status }
          end
        }
      end
    }
  end

  private
    def set_source
      if params[:room_id].present?
        room = Current.user.rooms.find(params[:room_id])
        @source = if params[:thread_id].present?
          room.channel_threads.find(params[:thread_id]).messages.find(params[:message_id])
        else
          room.root_messages.find(params[:message_id])
        end
      else
        @source = Current.user.reachable_messages.find(params[:message_id])
      end
    end

    def forward_payload
      payload = params[:forward].presence || params
      return payload unless payload.respond_to?(:permit)

      payload.permit(:note, destinations: [ :room_id, :thread_id ])
    end

    def forward_note
      forward_payload[:note].to_s.presence
    end

    def forward_destinations
      raw = forward_payload[:destinations]
      Array(raw).map do |destination|
        if destination.respond_to?(:to_h)
          destination.to_h.slice("room_id", "thread_id", :room_id, :thread_id)
        else
          destination
        end
      end
    end

    def render_error(message, status: :unprocessable_content)
      respond_to do |format|
        format.html { head status }
        format.json { render json: { error: message }, status: status }
        format.any { head status }
      end
    end
end
