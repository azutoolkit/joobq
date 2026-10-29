# crystal-redis's Connection finalizer calls buffered socket #close, which may
# flush and access the current fiber/event loop. Crystal 1.22 can run GC on its
# monitor thread, where there is no execution context. That killed the monitor
# during a passing spec run. Leave GC cleanup to the stdlib socket/SSL finalizers,
# which release their own resources without flushing. Explicit #close is intact.
# Remove this compatibility override when the dependency fixes its finalizer.
class Redis::Connection
  def finalize : Nil
  end
end
