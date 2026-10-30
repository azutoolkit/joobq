# Compile separately: the main spec suite defines concrete jobs and queues,
# which hides type-inference failures in a freshly generated worker.
require "../../src/joobq"

JoobQ.config.rest_api_enabled = false
JoobQ.forge
