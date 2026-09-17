class CreateGithubPullRequestThreads < ActiveRecord::Migration[8.2]
  def change
    create_table :github_pull_request_threads do |t|
      t.references :github_pull_request, null: false, foreign_key: true
      t.references :room, null: false, foreign_key: true
      t.references :channel_thread, null: false, foreign_key: true
      t.timestamps
    end

    add_index :github_pull_request_threads, %i[ github_pull_request_id room_id ],
      unique: true, name: "index_github_pr_threads_on_pr_and_room"
    add_index :github_pull_request_threads, :channel_thread_id,
      unique: true, name: "index_github_pr_threads_on_thread"
  end
end
