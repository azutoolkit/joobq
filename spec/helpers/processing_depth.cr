module JoobQ
  # Jobs in processing for a queue across every process's own list (`joobq:v1:processing:<queue>:<owner>`) and the
  # legacy shared list. The probe runs in another process, so its list key carries a pid this spec does not know.
  def self.processing_depth(redis, queue : String) : Int64
    prefix = "joobq:v1:processing:#{queue}"
    total = 0_i64
    cursor = 0_i64
    loop do
      result = redis.scan(cursor, match: "#{prefix}*", count: 100)
      cursor = result[0].as(String).to_i64
      result[1].as(Array).each do |key|
        key_str = key.as(String)
        total += redis.llen(key_str) if key_str == prefix || key_str.starts_with?("#{prefix}:")
      end
      break if cursor == 0
    end
    total
  end
end
