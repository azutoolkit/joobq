require "../src/joobq"
require "./jobs/*"
JoobQ.configure do |_|
  queue "queue:test", 30, TestJob
  queue "queue:fail", 20, FailJob
end



JoobQ.forge
sleep
