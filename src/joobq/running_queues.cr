module JoobQ
  # The `Queue` instances started in this process, by queue name. Every `RedisStore` of a process shares one
  # `owner_id`, so every instance of a name shares one processing list: restart recovery (which drains that list)
  # may run only for the first instance of a name, or it would re-queue the jobs a running instance holds.
  # Process-global on purpose, so it outlives `JoobQ.reset_config`/`set_config` while queues still run.
  module RunningQueues
    @@lock = Sync::Mutex.new

    # Holds the instances themselves, not their object ids: a started queue that is never stopped stays registered,
    # and its address cannot be reused by a new instance that would then wrongly count as "not first".
    @@instances = Hash(String, Array(BaseQueue)).new

    # Registers *queue* under *name* and yields whether it is the first instance of that name, still holding the
    # lock, so no other instance starts while the block recovers. If the block raises, the registration is undone.
    def self.register(name : String, queue : BaseQueue, & : Bool -> _) : Nil
      @@lock.synchronize do
        instances = @@instances[name] ||= Array(BaseQueue).new
        first = instances.empty?
        instances << queue
        begin
          yield first
        rescue ex
          remove(name, queue)
          raise ex
        end
      end
    end

    def self.deregister(name : String, queue : BaseQueue) : Nil
      @@lock.synchronize { remove(name, queue) }
    end

    private def self.remove(name : String, queue : BaseQueue) : Nil
      return unless instances = @@instances[name]?
      instances.reject!(&.same?(queue))
      @@instances.delete(name) if instances.empty?
    end
  end
end
