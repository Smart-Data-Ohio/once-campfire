class DowncaseGithubPullRequestNames < ActiveRecord::Migration[8.2]
  def change
    reversible do |direction|
      direction.up do
        Github::PullRequest.collapse_case_duplicates!
      end
    end
  end
end
