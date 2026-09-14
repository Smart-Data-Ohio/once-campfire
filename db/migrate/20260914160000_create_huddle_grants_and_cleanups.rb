class CreateHuddleGrantsAndCleanups < ActiveRecord::Migration[8.2]
  def change
    create_table :huddle_grants do |t|
      t.string :identity, null: false
      t.string :room_name, null: false
      t.integer :session_id, null: false
      t.integer :user_id, null: false
      t.integer :membership_id, null: false
      t.integer :room_id, null: false
      t.datetime :revoked_at
      t.timestamps

      t.index :identity, unique: true
      t.index :session_id
      t.index :user_id
      t.index :membership_id
      t.index :room_id
      t.index [ :session_id, :membership_id ], unique: true, where: "revoked_at IS NULL",
        name: "index_active_huddle_grants_on_session_and_membership"
    end

    create_table :huddle_cleanups do |t|
      t.string :operation, null: false
      t.integer :huddle_grant_id
      t.string :room_name, null: false
      t.string :identity
      t.datetime :enqueued_at
      t.datetime :last_attempted_at
      t.datetime :next_attempt_at
      t.integer :attempts, null: false, default: 0
      t.datetime :completed_at
      t.timestamps

      t.index :huddle_grant_id
      t.index [ :completed_at, :next_attempt_at ]
      t.index [ :operation, :huddle_grant_id ], unique: true,
        where: "operation = 'remove_participant'",
        name: "index_huddle_cleanups_on_unique_participant_removal"
      t.index [ :operation, :room_name ], unique: true,
        where: "operation = 'delete_room'",
        name: "index_huddle_cleanups_on_unique_room_deletion"
    end
  end
end
