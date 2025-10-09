require "json"

module JoobQ
  # Simple in-memory cache for API data with TTL support
  # This cache helps reduce redundant Redis queries for frequently accessed data
  class APICache
    Log = ::Log.for("API Cache")

    # Cache entry structure
    private struct CacheEntry(T)
      getter data : T
      getter expires_at : Time

      def initialize(@data : T, ttl : Time::Span)
        @expires_at = Time.local + ttl
      end

      def expired? : Bool
        Time.local >= @expires_at
      end
    end

    # Singleton instance
    @@instance : APICache?

    def self.instance : APICache
      @@instance ||= new
    end

    # Cache storage with different TTLs for different data types
    @processing_jobs_cache : CacheEntry(Array(String))?
    @delayed_jobs_cache : CacheEntry(Array(String))?
    @dead_jobs_cache : CacheEntry(Array(String))?
    @error_stats_cache : CacheEntry(Hash(String, Int32))?
    @recent_errors_cache : CacheEntry(Array(ErrorContext))?
    @queue_metrics_cache : CacheEntry(Hash(String, RedisStore::QueueMetrics))?

    # Mutex for thread-safe cache operations
    @mutex : Mutex = Mutex.new

    # Default TTLs for different data types
    PROCESSING_JOBS_TTL = 2.seconds
    DELAYED_JOBS_TTL    = 5.seconds
    DEAD_JOBS_TTL       = 10.seconds
    ERROR_STATS_TTL     = 3.seconds
    RECENT_ERRORS_TTL   = 3.seconds
    QUEUE_METRICS_TTL   = 5.seconds

    private def initialize
      Log.info &.emit("Initializing API cache")
    end

    # Public API methods with type-specific caching

    def get_processing_jobs(limit : Int32 = 100, & : -> Array(String)) : Array(String)
      @mutex.synchronize do
        entry = @processing_jobs_cache
        if entry && !entry.expired?
          Log.debug &.emit("Cache hit", key: "processing_jobs")
          return entry.data
        end

        # Cache miss - fetch fresh data
        Log.debug &.emit("Cache miss", key: "processing_jobs")
        fresh_data = yield
        @processing_jobs_cache = CacheEntry(Array(String)).new(fresh_data, PROCESSING_JOBS_TTL)
        fresh_data
      end
    end

    def get_delayed_jobs(limit : Int32 = 1000, & : -> Array(String)) : Array(String)
      @mutex.synchronize do
        entry = @delayed_jobs_cache
        if entry && !entry.expired?
          Log.debug &.emit("Cache hit", key: "delayed_jobs")
          return entry.data
        end

        # Cache miss - fetch fresh data
        Log.debug &.emit("Cache miss", key: "delayed_jobs")
        fresh_data = yield
        @delayed_jobs_cache = CacheEntry(Array(String)).new(fresh_data, DELAYED_JOBS_TTL)
        fresh_data
      end
    end

    def get_dead_jobs(limit : Int32 = 50, & : -> Array(String)) : Array(String)
      @mutex.synchronize do
        entry = @dead_jobs_cache
        if entry && !entry.expired?
          Log.debug &.emit("Cache hit", key: "dead_jobs")
          return entry.data
        end

        # Cache miss - fetch fresh data
        Log.debug &.emit("Cache miss", key: "dead_jobs")
        fresh_data = yield
        @dead_jobs_cache = CacheEntry(Array(String)).new(fresh_data, DEAD_JOBS_TTL)
        fresh_data
      end
    end

    def get_error_stats(& : -> Hash(String, Int32)) : Hash(String, Int32)
      @mutex.synchronize do
        entry = @error_stats_cache
        if entry && !entry.expired?
          Log.debug &.emit("Cache hit", key: "error_stats")
          return entry.data
        end

        # Cache miss - fetch fresh data
        Log.debug &.emit("Cache miss", key: "error_stats")
        fresh_data = yield
        @error_stats_cache = CacheEntry(Hash(String, Int32)).new(fresh_data, ERROR_STATS_TTL)
        fresh_data
      end
    end

    def get_recent_errors(limit : Int32 = 20, & : -> Array(ErrorContext)) : Array(ErrorContext)
      @mutex.synchronize do
        entry = @recent_errors_cache
        if entry && !entry.expired?
          Log.debug &.emit("Cache hit", key: "recent_errors")
          return entry.data
        end

        # Cache miss - fetch fresh data
        Log.debug &.emit("Cache miss", key: "recent_errors")
        fresh_data = yield
        @recent_errors_cache = CacheEntry(Array(ErrorContext)).new(fresh_data, RECENT_ERRORS_TTL)
        fresh_data
      end
    end

    def get_queue_metrics(& : -> Hash(String, RedisStore::QueueMetrics)) : Hash(String, RedisStore::QueueMetrics)
      @mutex.synchronize do
        entry = @queue_metrics_cache
        if entry && !entry.expired?
          Log.debug &.emit("Cache hit", key: "queue_metrics")
          return entry.data
        end

        # Cache miss - fetch fresh data
        Log.debug &.emit("Cache miss", key: "queue_metrics")
        fresh_data = yield
        @queue_metrics_cache = CacheEntry(Hash(String, RedisStore::QueueMetrics)).new(fresh_data, QUEUE_METRICS_TTL)
        fresh_data
      end
    end

    # Cache invalidation methods - called when data is mutated

    def invalidate_processing_jobs : Nil
      @mutex.synchronize do
        Log.debug &.emit("Invalidating cache", key: "processing_jobs")
        @processing_jobs_cache = nil
      end
    end

    def invalidate_delayed_jobs : Nil
      @mutex.synchronize do
        Log.debug &.emit("Invalidating cache", key: "delayed_jobs")
        @delayed_jobs_cache = nil
      end
    end

    def invalidate_dead_jobs : Nil
      @mutex.synchronize do
        Log.debug &.emit("Invalidating cache", key: "dead_jobs")
        @dead_jobs_cache = nil
      end
    end

    def invalidate_error_stats : Nil
      @mutex.synchronize do
        Log.debug &.emit("Invalidating cache", key: "error_stats")
        @error_stats_cache = nil
      end
    end

    def invalidate_recent_errors : Nil
      @mutex.synchronize do
        Log.debug &.emit("Invalidating cache", key: "recent_errors")
        @recent_errors_cache = nil
      end
    end

    def invalidate_queue_metrics : Nil
      @mutex.synchronize do
        Log.debug &.emit("Invalidating cache", key: "queue_metrics")
        @queue_metrics_cache = nil
      end
    end

    # Clear all caches
    def clear_all : Nil
      @mutex.synchronize do
        Log.info &.emit("Clearing all caches")
        @processing_jobs_cache = nil
        @delayed_jobs_cache = nil
        @dead_jobs_cache = nil
        @error_stats_cache = nil
        @recent_errors_cache = nil
        @queue_metrics_cache = nil
      end
    end

    # Get cache statistics
    def stats
      @mutex.synchronize do
        {
          processing_jobs: {
            cached:  !@processing_jobs_cache.nil?,
            expired: @processing_jobs_cache.try(&.expired?) || false,
          },
          delayed_jobs: {
            cached:  !@delayed_jobs_cache.nil?,
            expired: @delayed_jobs_cache.try(&.expired?) || false,
          },
          dead_jobs: {
            cached:  !@dead_jobs_cache.nil?,
            expired: @dead_jobs_cache.try(&.expired?) || false,
          },
          error_stats: {
            cached:  !@error_stats_cache.nil?,
            expired: @error_stats_cache.try(&.expired?) || false,
          },
          recent_errors: {
            cached:  !@recent_errors_cache.nil?,
            expired: @recent_errors_cache.try(&.expired?) || false,
          },
          queue_metrics: {
            cached:  !@queue_metrics_cache.nil?,
            expired: @queue_metrics_cache.try(&.expired?) || false,
          },
        }
      end
    end
  end
end
