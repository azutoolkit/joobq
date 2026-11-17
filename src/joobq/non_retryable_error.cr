module JoobQ
  # Raise this (or a subclass) from `perform` when running the job again cannot succeed: a declined card, a record
  # that no longer exists, input that will never validate. The job goes to the dead letter queue at once, with its
  # error recorded, whatever retries it has left.
  #
  # ```
  # class ChargeJob
  #   include JoobQ::Job
  #
  #   class Declined < JoobQ::NonRetryableError
  #   end
  #
  #   def perform
  #     raise Declined.new("card declined") if declined?
  #   end
  # end
  # ```
  class NonRetryableError < Exception
    include Coded
    joobq_error_code "JQ-302"

    # The message is yours, so it stays exactly as raised: nothing is appended to it (other coded errors, which
    # JoobQ raises itself, end with their code and URL). The code is still on the error: `joobq_error_code`.
    def message : String?
      @message
    end
  end
end
