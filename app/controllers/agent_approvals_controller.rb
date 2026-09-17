class AgentApprovalsController < ApplicationController
  allow_agent_access only: :update
  allow_bot_access only: :update

  # PATCH /agent_approvals/:id?decision=approved|denied (session, deciders
  # only). Approving or denying marks every decider's inbox item handled.
  # Anything else — plain members, agent tokens, bots — gets 404.
  def update
    if authenticated_by.agent_token? || authenticated_by.bot_key? || Current.user&.bot?
      head :not_found
      return
    end

    @approval = AgentApproval.includes(:agent, :room).find_by(id: params[:id])
    unless @approval && decider?(@approval.agent, Current.user)
      head :not_found
      return
    end

    decision = params[:decision].to_s
    unless AgentApproval::DECISIONS.include?(decision)
      respond_to do |format|
        format.html { redirect_back_or_to activity_items_path, alert: "Choose Approve or Deny.", status: :see_other }
        format.json { render json: { error: "Decision must be approved or denied" }, status: :unprocessable_entity }
      end
      return
    end

    begin
      @approval.decide!(decision: decision, by: Current.user, note: params[:decision_note].presence || params[:note].presence)
    rescue ActiveRecord::RecordInvalid
      message = @approval.errors.full_messages.to_sentence.presence || "Request cannot be decided"
      respond_to do |format|
        format.html { redirect_back_or_to activity_items_path, alert: message, status: :see_other }
        format.json { render json: { error: message }, status: :unprocessable_entity }
      end
      return
    end

    respond_to do |format|
      format.html { redirect_back_or_to activity_items_path, notice: "Request #{@approval.status}.", status: :see_other }
      format.json { render json: decision_payload(@approval) }
    end
  end

  private
    def decider?(agent, user)
      return false unless user&.active? && !user.bot?
      return false unless agent&.user&.active?

      user.administrator? || agent.owner_id == user.id
    end

    def decision_payload(approval)
      {
        id: approval.id,
        status: approval.effective_status,
        decided_by: approval.decided_by&.name,
        decided_by_id: approval.decided_by_id,
        decided_at: approval.decided_at&.utc,
        decision_note: approval.decision_note,
        note: approval.decision_note
      }.compact
    end
end
