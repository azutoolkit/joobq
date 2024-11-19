require "./config"
Log.info { "Stats Enabled: #{JoobQ.config.stats_enabled?}" }

JoobQ.forge
sleep
