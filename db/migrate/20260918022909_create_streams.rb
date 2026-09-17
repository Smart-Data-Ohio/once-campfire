class CreateStreams < ActiveRecord::Migration[8.2]
  def change
    create_table :streams do |t|
      t.integer :room_id, null: false
      t.integer :membership_id, null: false
      t.integer :user_id, null: false
      t.string :quality, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at

      t.timestamps
    end

    add_index :streams, :room_id, unique: true, where: "ended_at IS NULL"
    add_index :streams, :membership_id
  end
end
