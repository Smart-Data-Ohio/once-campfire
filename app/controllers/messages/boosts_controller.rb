class Messages::BoostsController < ApplicationController
  before_action :set_message
  before_action :set_boost, only: :destroy

  def index
  end

  def new
  end

  def create
    content = Boost.resolve_content(boost_params[:content])
    @message.with_lock do
      @message.reload
      existing = @message.boosts.where(booster: Current.user, content:).to_a if EmojiHelper::REACTIONS.key?(content)

      if existing.present?
        # Old data may contain duplicate reaction rows. Preserve it until this
        # person explicitly toggles the reaction, then remove every duplicate
        # so the next toggle has one clear meaning.
        existing.each(&:destroy!)
        @boost = existing.first
      else
        @boost = @message.boosts.create!(boost_params)
      end
    end

    broadcast_reactions
    redirect_to message_boosts_url(@message)
  rescue ActiveRecord::RecordInvalid
    redirect_to message_boosts_url(@message)
  end

  def destroy
    @boost.destroy!
    broadcast_reactions
  end

  private
    def set_message
      @message = Current.user.reachable_messages.find(params[:message_id])
    end

    def set_boost
      @boost = @message.boosts.find_by!(id: params[:id], booster: Current.user)
    end

    def boost_params
      params.require(:boost).permit(:content)
    end

    def broadcast_create
      stream_target = @boost.message.conversation
      @boost.broadcast_append_to stream_target, :messages,
        target: "boosts_message_#{@boost.message.client_message_id}", partial: "messages/boosts/boost", attributes: { maintain_scroll: true }
    end

    def broadcast_remove
      @boost.broadcast_remove_to @boost.message.conversation, :messages
    end

    def broadcast_reactions
      @message.broadcast_replace_to @message.conversation, :messages,
        target: ActionView::RecordIdentifier.dom_id(@message, :boosts),
        partial: "messages/boosts/reactions", attributes: { maintain_scroll: true }
    end
end
