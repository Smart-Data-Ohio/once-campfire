# YJIT is enabled for the web process only. It costs ~45 MB RSS in the process
# that serves requests, which is worth it there but not in the workers or the
# reconciler, and this box has no swap. thrust passes the environment through to
# bin/start-app.
web: RUBY_YJIT_ENABLE=1 bundle exec thrust bin/start-app
redis: redis-server config/redis.conf
workers: FORK_PER_JOB=false INTERVAL=0.1 bundle exec resque-pool
huddle_reconciler: bundle exec bin/huddle-reconcile
