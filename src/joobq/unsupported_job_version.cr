module JoobQ
  # A stored job whose format version this JoobQ does not know (written by a newer JoobQ). It is a `JSON::ParseException`,
  # so a worker dead-letters it as an unreadable job (its log line carries this message) with the payload intact, and the
  # job can be redriven once the process is upgraded.
  class UnsupportedJobVersion < JSON::ParseException
    getter version : Int32

    def initialize(@version : Int32)
      text = "job has format version #{@version}; this JoobQ reads up to #{Job::FORMAT_VERSION}: upgrade JoobQ"
      super(text, 0, 0)
      @message = text # ParseException appends the position in the text, which means nothing here
    end
  end
end
