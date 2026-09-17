class CreateBoards < ActiveRecord::Migration[8.2]
  def change
    add_column :channel_threads, :result_markdown, :text
    add_column :channel_threads, :result_updated_at, :datetime
    add_column :channel_threads, :result_updated_by_id, :integer
    add_column :channel_threads, :run_url, :string

    create_table :thread_tags do |t|
      t.integer :channel_thread_id, null: false
      t.string :name, null: false
      t.timestamps
      t.index [ :channel_thread_id, :name ], unique: true
      t.index :name
    end
  end
end
