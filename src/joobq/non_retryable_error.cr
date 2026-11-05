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
  end
end
