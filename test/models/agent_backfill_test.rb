require "test_helper"
require_relative "../../db/migrate/20260916000000_create_agents"

class AgentBackfillTest < ActiveSupport::TestCase
  test "backfill creates one ownerless workspace agent per bot user" do
    Agent.delete_all

    CreateAgents.new.backfill_agents_for_existing_bots

    assert_equal User.where(role: :bot).ids.sort, Agent.pluck(:user_id).sort
    assert Agent.all.all?(&:workspace?)
    assert Agent.all.all? { |agent| agent.owner_id.nil? }
  end
end
