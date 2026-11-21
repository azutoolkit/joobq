require "./spec_helper"

# The validator accepts what cron_parser runs: `*`, `*/N`, `N`, `A-B`, `A-B/N` and lists of them, each inside its field's range.
describe "YAML cron pattern validation" do
  validate = ->(pattern : String) do
    yaml = "joobq:\n  schedulers:\n    - cron_jobs:\n        - pattern: #{pattern.inspect}\n          job: \"TestJob\"\n"
    JoobQ::ConfigValidator.validate(YAML.parse(yaml))
  end

  accepted = [
    "* * * * *", "0 */6 * * *", "*/15 * * * *", "1-5/2 * * * *", "0,30 * * * *", "0 0 1 1 *", "59 23 31 12 7",
    "0 9-17 * * 1-5", "0 0 * * 0", "0 */6,12 * * *", "*/1 */1 */1 */1 */1", "*/100 * * * *", "0 0 * * 0-7", "0 0 * * 7",
    "0 0 * * 1,7", "0 0 * * 0-6/2", "0-59 0-23 1-31 1-12 0-6", "5,10-20/5 * * * *", "0\t*/6\t*\t*\t*",
  ]

  accepted.each do |pattern|
    it "accepts #{pattern.inspect}, and cron_parser can run it" do
      validate.call(pattern)
      CronParser.new(pattern).next(Time.utc).should be_a(Time)
    end
  end

  {
    "61 * * * *"              => "minute",
    "60 * * * *"              => "minute",
    "* 24 * * *"              => "hour",
    "* * 0 * *"               => "day",
    "* * 32 * *"              => "day",
    "* * * 0 *"               => "month",
    "* * * 13 *"              => "month",
    "* * * * 8"               => "weekday",
    "*/0 * * * *"             => "minute",
    "5-1 * * * *"             => "minute",
    "1-5/0 * * * *"           => "minute",
    "0 */ * * *"              => "hour",
    "0,,5 * * * *"            => "minute",
    "a * * * *"               => "minute",
    "*/x * * * *"             => "minute",
    "5/10 * * * *"            => "minute",
    "0 0 * * 7-7"             => "weekday",
    "0 0 * * 7-7/2"           => "weekday",
    "0 0 * * 1-7"             => "weekday",
    "0 0 * * 6-7"             => "weekday",
    "0 0 * * 1-8"             => "weekday",
    "0-60 * * * *"            => "minute",
    "0,61 * * * *"            => "minute",
    "0 0 * 1-13/2 *"          => "month",
    "0 0 0-31/2 * *"          => "day",
    "*/99999999999 * * * *"   => "minute",
    "99999999999 * * * *"     => "minute",
    "1-99999999999 * * * *"   => "minute",
    "1-5/99999999999 * * * *" => "minute",
  }.each do |pattern, field|
    it "rejects #{pattern.inspect}, naming the #{field} field" do
      expect_raises(JoobQ::ConfigValidationError, "invalid #{field} field") { validate.call(pattern) }
    end
  end

  it "rejects a pattern that does not have five fields" do
    expect_raises(JoobQ::ConfigValidationError, "must have 5 fields") { validate.call("* * * *") }
    expect_raises(JoobQ::ConfigValidationError, "must have 5 fields") { validate.call("* * * * * *") }
  end
end
