class CreateWorkThreadLinks < ActiveRecord::Migration[8.2]
  def change
    create_table :work_thread_links do |t|
      t.references :channel_thread, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.references :github_pull_request, foreign_key: true
      t.references :event, foreign_key: { on_delete: :cascade }
      t.string :url
      t.string :title
      t.references :created_by, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :work_thread_links, %i[ channel_thread_id kind github_pull_request_id ],
      unique: true, name: "index_work_thread_links_on_thread_kind_and_pr",
      where: "github_pull_request_id IS NOT NULL"
    add_index :work_thread_links, %i[ channel_thread_id event_id ],
      unique: true, name: "index_work_thread_links_on_thread_and_event",
      where: "event_id IS NOT NULL"
    add_index :work_thread_links, %i[ channel_thread_id url ],
      unique: true, name: "index_work_thread_links_on_thread_and_url",
      where: "url IS NOT NULL"
  end
end
