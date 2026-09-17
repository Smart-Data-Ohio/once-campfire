# One work payload for every agent surface: GET /agents/work, the work key
# in assignment event polling and webhooks (which adds the legacy
# thread_id, status, and assigned_by keys), and the board post endpoints.
# Additive only: existing keys keep their names and shapes.
module Agents
  class WorkPayload
    def self.for(thread)
      room = thread.room
      owner = thread.work_owner

      {
        id: thread.id,
        room_id: thread.room_id,
        board_id: room.board? ? room.id : nil,
        board_name: room.board? ? room.name : nil,
        title: thread.name,
        work_status: thread.work_status,
        owner: owner ? { id: owner.id, name: owner.name, agent: owner.bot? } : nil,
        tags: thread.tag_names,
        result: thread.result_markdown,
        result_updated_at: thread.result_updated_at&.utc,
        run_url: thread.run_url,
        url: Rails.application.routes.url_helpers.room_path(room, thread: thread.id),
        updated_at: thread.updated_at&.utc,
        links: WorkThreadLink.agent_payloads_for(thread)
      }
    end
  end
end
